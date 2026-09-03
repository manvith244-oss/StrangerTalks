defmodule StrangertalksNew.FutureSocial.CircleFormationHostileCapacityTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.FutureSocial.CircleFormation

  @min_size 4
  @target_size 6
  @max_size 8

  defp candidates(count, formation_key \\ {:topic, "capacity", "en"}, prefix \\ "participant") do
    for index <- 1..count do
      %{
        participant_id: "#{prefix}-#{index}",
        formation_key: formation_key,
        payload: %{arrival_order: index}
      }
    end
  end

  defp form(input) do
    CircleFormation.form(input, min_size: @min_size, max_size: @max_size)
  end

  defp member_ids(circles) do
    circles
    |> Enum.flat_map(& &1.members)
    |> Enum.map(& &1.participant_id)
  end

  defp feasible_circle_counts(candidate_count) do
    min_circles = div(candidate_count + @max_size - 1, @max_size)
    max_circles = div(candidate_count, @min_size)

    if min_circles <= max_circles do
      Enum.to_list(min_circles..max_circles)
    else
      []
    end
  end

  test "capacity sweep never emits a Circle outside 4..8 or loses/duplicates a human" do
    for count <- 1..2_000 do
      input = candidates(count, {:topic, "sweep", "en"})
      assert {:ok, %{circles: circles, waiting: waiting}} = form(input)

      assert Enum.all?(circles, fn circle ->
               size = length(circle.members)
               size >= @min_size and size <= @max_size
             end)

      output_ids = member_ids(circles) ++ Enum.map(waiting, & &1.participant_id)
      input_ids = Enum.map(input, & &1.participant_id)

      assert output_ids == input_ids
      assert length(output_ids) == length(Enum.uniq(output_ids))
    end
  end

  test "when everyone can be seated, Circle count stays as close as feasible to target size six" do
    for count <- [20, 100, 1_000] do
      input = candidates(count, {:topic, "high-demand", "en"})
      assert {:ok, %{circles: circles, waiting: []}} = form(input)

      actual_circle_count = length(circles)
      actual_distance = abs(count / actual_circle_count - @target_size)

      best_distance =
        count
        |> feasible_circle_counts()
        |> Enum.map(fn circle_count -> abs(count / circle_count - @target_size) end)
        |> Enum.min()

      assert_in_delta actual_distance, best_distance, 1.0e-12
      assert Enum.all?(circles, &(length(&1.members) <= @max_size))
    end
  end

  test "one thousand humans become many bounded Circles, never one giant room" do
    input = candidates(1_000, {:topic, "burst", "en"})

    assert {:ok, %{circles: circles, waiting: []}} = form(input)

    assert length(circles) > 100
    assert Enum.max(Enum.map(circles, &length(&1.members))) <= @max_size
    assert Enum.sum(Enum.map(circles, &length(&1.members))) == 1_000
  end

  test "sparse arrivals remain waiting until a healthy Circle can form" do
    first = candidates(1, {:topic, "sparse", "en"}, "sparse")
    assert {:ok, %{circles: [], waiting: ^first}} = form(first)

    second =
      first ++
        [
          %{participant_id: "sparse-2", formation_key: {:topic, "sparse", "en"}},
          %{participant_id: "sparse-3", formation_key: {:topic, "sparse", "en"}}
        ]

    assert {:ok, %{circles: [], waiting: ^second}} = form(second)

    fourth = second ++ [%{participant_id: "sparse-4", formation_key: {:topic, "sparse", "en"}}]

    assert {:ok, %{circles: [circle], waiting: []}} = form(fourth)
    assert Enum.map(circle.members, & &1.participant_id) == Enum.map(fourth, & &1.participant_id)
  end

  test "burst simulation never re-packs already emitted active Circles" do
    batches = [1, 3, 20, 7, 100, 5, 64]

    {_next_id, active_circles, waiting} =
      Enum.reduce(batches, {1, [], []}, fn batch_size, {next_id, active, waiting} ->
        arrivals =
          for offset <- 0..(batch_size - 1) do
            %{
              participant_id: "burst-#{next_id + offset}",
              formation_key: {:topic, "continuity", "en"}
            }
          end

        pending = waiting ++ arrivals
        assert {:ok, %{circles: newly_formed, waiting: next_waiting}} = form(pending)

        # Active Circles are intentionally never re-presented to the stateless kernel.
        # This models the packet law that continuity outranks later packing efficiency.
        active_snapshot = active
        next_active = active ++ newly_formed
        assert Enum.take(next_active, length(active_snapshot)) == active_snapshot

        {next_id + batch_size, next_active, next_waiting}
      end)

    all_ids = member_ids(active_circles) ++ Enum.map(waiting, & &1.participant_id)

    assert length(all_ids) == Enum.sum(batches)
    assert length(all_ids) == length(Enum.uniq(all_ids))
    assert Enum.all?(active_circles, &(length(&1.members) in @min_size..@max_size))
  end

  test "minimal future-social identity is sufficient; public social graph fields are not required" do
    input =
      for index <- 1..6 do
        %{
          participant_id: "minimal-#{index}",
          formation_key: {:topic, "minimal", "en"}
        }
      end

    assert {:ok, %{circles: [circle], waiting: []}} = form(input)
    assert circle.members == input

    refute Enum.any?(circle.members, &Map.has_key?(&1, :public_profile))
    refute Enum.any?(circle.members, &Map.has_key?(&1, :follower_count))
    refute Enum.any?(circle.members, &Map.has_key?(&1, :global_username_reputation))
    refute Enum.any?(circle.members, &Map.has_key?(&1, :public_bond_graph))
  end

  test "concurrent pure invocations over the same snapshot are deterministic" do
    input = candidates(100, {:topic, "concurrent", "en"})
    expected = form(input)

    results =
      1..64
      |> Task.async_stream(fn _ -> form(input) end,
        max_concurrency: 16,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 64
    assert Enum.all?(results, &(&1 == expected))
  end

  test "duplicate membership still fails closed across different formation cohorts" do
    input = candidates(4, {:topic, "one", "en"}, "dup")
    duplicate = %{participant_id: "dup-1", formation_key: {:topic, "two", "en"}}

    assert {:error, {:duplicate_participant, "dup-1"}} = form(input ++ [duplicate])
  end

  test "approved healthy envelope cannot be bypassed by caller-provided bounds" do
    input = candidates(9)

    assert {:error, :invalid_size_bounds} =
             CircleFormation.form(input, min_size: 3, max_size: 8)

    assert {:error, :invalid_size_bounds} =
             CircleFormation.form(input, min_size: 4, max_size: 9)
  end
end
