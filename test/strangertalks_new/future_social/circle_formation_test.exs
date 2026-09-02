defmodule StrangertalksNew.FutureSocial.CircleFormationTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.FutureSocial.CircleFormation

  @encounter_doors [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]

  defp candidates(count, formation_key) do
    for index <- 1..count do
      %{
        participant_id: "participant-#{index}",
        formation_key: formation_key,
        payload: %{arrival_order: index}
      }
    end
  end

  test "keeps a cohort waiting until the minimum Circle size exists" do
    input = candidates(3, {:topic, "rain", "en"})

    assert {:ok, %{circles: [], waiting: ^input}} =
             CircleFormation.form(input, min_size: 4, max_size: 6)
  end

  test "forms one Circle at the exact minimum without changing member order" do
    input = candidates(4, {:topic, "rain", "en"})

    assert {:ok,
            %{
              circles: [
                %{
                  formation_key: {:topic, "rain", "en"},
                  members: ^input
                }
              ],
              waiting: []
            }} = CircleFormation.form(input, min_size: 4, max_size: 6)
  end

  test "balances a feasible cohort into bounded Circles while seating everyone" do
    input = candidates(13, {:topic, "final", "en"})

    assert {:ok, %{circles: circles, waiting: []}} =
             CircleFormation.form(input, min_size: 4, max_size: 6)

    assert Enum.map(circles, &length(&1.members)) == [5, 4, 4]

    assert Enum.flat_map(circles, & &1.members) == input
  end

  test "leaves only the unavoidable remainder waiting when the full cohort cannot be partitioned" do
    input = candidates(7, {:topic, "final", "en"})

    assert {:ok, %{circles: [circle], waiting: [waiting]}} =
             CircleFormation.form(input, min_size: 4, max_size: 6)

    assert length(circle.members) == 6

    assert Enum.map(circle.members, & &1.participant_id) ==
             Enum.map(Enum.take(input, 6), & &1.participant_id)

    assert waiting.participant_id == "participant-7"
  end

  test "never mixes independent future-social formation keys" do
    first = candidates(4, {:topic, "rain", "en"})

    second =
      candidates(4, {:topic, "cricket", "en"})
      |> Enum.map(fn candidate ->
        %{candidate | participant_id: "second-#{candidate.participant_id}"}
      end)

    assert {:ok, %{circles: [first_circle, second_circle], waiting: []}} =
             CircleFormation.form(first ++ second, min_size: 4, max_size: 6)

    assert first_circle.formation_key == {:topic, "rain", "en"}
    assert first_circle.members == first
    assert second_circle.formation_key == {:topic, "cricket", "en"}
    assert second_circle.members == second
  end

  test "rejects duplicate participant authority instead of silently placing one human twice" do
    [first | rest] = candidates(4, {:topic, "rain", "en"})
    duplicate = %{first | formation_key: {:topic, "cricket", "en"}}

    assert {:error, {:duplicate_participant, first.participant_id}} ==
             CircleFormation.form([first | rest] ++ [duplicate], min_size: 4, max_size: 6)
  end

  test "rejects invalid human-scale size bounds" do
    input = candidates(4, {:topic, "rain", "en"})

    assert {:error, :invalid_size_bounds} ==
             CircleFormation.form(input, min_size: 0, max_size: 6)

    assert {:error, :invalid_size_bounds} ==
             CircleFormation.form(input, min_size: 6, max_size: 4)
  end

  test "is deterministic for the same ordered candidate set and policy" do
    input =
      candidates(13, {:topic, "rain", "en"}) ++
        (candidates(7, {:topic, "cricket", "te"})
         |> Enum.map(fn candidate ->
           %{candidate | participant_id: "te-#{candidate.participant_id}"}
         end))

    first = CircleFormation.form(input, min_size: 4, max_size: 6)
    second = CircleFormation.form(input, min_size: 4, max_size: 6)

    assert first == second
  end

  test "future-social formation does not widen the one-to-one Encounter Door enums" do
    assert Ecto.Enum.values(StrangertalksNew.Matching, :door_type) == @encounter_doors
    assert Ecto.Enum.values(StrangertalksNew.Conversation, :door_type) == @encounter_doors
    assert Ecto.Enum.values(StrangertalksNew.Relationship, :origin_door_type) == @encounter_doors

    assert Ecto.Enum.values(StrangertalksNew.Relationship, :origin_participant_a_door_type) ==
             @encounter_doors

    assert Ecto.Enum.values(StrangertalksNew.Relationship, :origin_participant_b_door_type) ==
             @encounter_doors
  end
end
