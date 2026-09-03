defmodule StrangertalksNew.FutureSocial.CircleFormation do
  @moduledoc """
  Deterministic, side-effect-free Circle formation primitive for future-social systems.

  This module deliberately does not depend on the existing one-to-one Encounter
  matching, Conversation, Relationship, queue, channel, or persistence layers.
  A future product entry point may be described as Happening/Fifth Door, but that
  does not make it an Encounter `door_type` and this kernel has no Door semantics.

  Callers provide an ordered candidate list and explicit human-scale size policy.
  Candidates sharing the same opaque `formation_key` may be placed together;
  candidates from different keys are never mixed. Input order is preserved within
  each cohort, making the result deterministic for the same inputs and policy.

  This module forms candidate groups only. It does not create durable Circles,
  authorize membership, run realtime lifecycle, apply safety policy, or persist
  anything. Active Circle members must not be re-presented as formation candidates;
  continuity and durable membership authority belong to later lifecycle packets.
  """

  @target_circle_size 6

  @type candidate :: %{
          required(:participant_id) => term(),
          required(:formation_key) => term(),
          optional(:payload) => term()
        }

  @type circle :: %{
          formation_key: term(),
          members: [candidate()]
        }

  @type result :: %{
          circles: [circle()],
          waiting: [candidate()]
        }

  @type formation_error ::
          :invalid_size_bounds
          | {:invalid_candidate, non_neg_integer()}
          | {:duplicate_participant, term()}

  @doc """
  Forms bounded Circles from ordered future-social candidates.

  Required options:

    * `:min_size` - smallest permitted Circle size, greater than zero
    * `:max_size` - largest permitted Circle size, greater than or equal to `:min_size`

  The kernel maximizes the number of seated candidates without ever emitting a
  Circle outside the supplied bounds. For the candidates that can be seated, it
  chooses the feasible Circle count whose average size is closest to the
  human-scale target of #{@target_circle_size}, then balances member counts as
  evenly as possible. When a cohort falls into an unavoidable capacity gap, the
  largest valid prefix is seated and the remainder stays waiting.
  """
  @spec form([candidate()], keyword()) :: {:ok, result()} | {:error, formation_error()}
  def form(candidates, opts) when is_list(candidates) and is_list(opts) do
    min_size = Keyword.get(opts, :min_size)
    max_size = Keyword.get(opts, :max_size)

    with :ok <- validate_size_bounds(min_size, max_size),
         :ok <- validate_candidates(candidates),
         :ok <- reject_duplicate_participants(candidates) do
      {cohort_order, cohorts} = build_cohorts(candidates)

      {reversed_circles, indexed_waiting} =
        Enum.reduce(cohort_order, {[], []}, fn formation_key, {circles_acc, waiting_acc} ->
          {cohort_circles, cohort_waiting} =
            cohorts
            |> Map.fetch!(formation_key)
            |> form_cohort(formation_key, min_size, max_size)

          {
            Enum.reverse(cohort_circles, circles_acc),
            Enum.reverse(cohort_waiting, waiting_acc)
          }
        end)

      circles = Enum.reverse(reversed_circles)

      waiting =
        indexed_waiting
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {:ok, %{circles: circles, waiting: waiting}}
    end
  end

  def form(_candidates, _opts), do: {:error, :invalid_size_bounds}

  defp validate_size_bounds(min_size, max_size)
       when is_integer(min_size) and is_integer(max_size) and min_size > 0 and
              max_size >= min_size,
       do: :ok

  defp validate_size_bounds(_min_size, _max_size), do: {:error, :invalid_size_bounds}

  defp validate_candidates(candidates) do
    case Enum.find_index(candidates, &invalid_candidate?/1) do
      nil -> :ok
      index -> {:error, {:invalid_candidate, index}}
    end
  end

  defp invalid_candidate?(candidate) when is_map(candidate) do
    not Map.has_key?(candidate, :participant_id) or
      not Map.has_key?(candidate, :formation_key) or
      is_nil(Map.get(candidate, :participant_id)) or
      is_nil(Map.get(candidate, :formation_key))
  end

  defp invalid_candidate?(_candidate), do: true

  defp reject_duplicate_participants(candidates) do
    Enum.reduce_while(candidates, MapSet.new(), fn candidate, seen ->
      participant_id = Map.fetch!(candidate, :participant_id)

      if MapSet.member?(seen, participant_id) do
        {:halt, {:error, {:duplicate_participant, participant_id}}}
      else
        {:cont, MapSet.put(seen, participant_id)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp build_cohorts(candidates) do
    {reversed_order, reversed_cohorts} =
      candidates
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {candidate, index}, {order, cohorts} ->
        formation_key = Map.fetch!(candidate, :formation_key)
        indexed_candidate = {index, candidate}

        case Map.fetch(cohorts, formation_key) do
          :error ->
            {[formation_key | order], Map.put(cohorts, formation_key, [indexed_candidate])}

          {:ok, existing} ->
            {order, Map.put(cohorts, formation_key, [indexed_candidate | existing])}
        end
      end)

    cohorts =
      Map.new(reversed_cohorts, fn {formation_key, indexed_candidates} ->
        {formation_key, Enum.reverse(indexed_candidates)}
      end)

    {Enum.reverse(reversed_order), cohorts}
  end

  defp form_cohort(indexed_candidates, formation_key, min_size, max_size) do
    candidate_count = length(indexed_candidates)
    {_packing_circle_count, seated_count} = allocation(candidate_count, min_size, max_size)
    circle_count = preferred_circle_count(seated_count, min_size, max_size)
    {seated, waiting} = Enum.split(indexed_candidates, seated_count)
    sizes = circle_sizes(seated_count, circle_count)

    {circles, []} =
      Enum.map_reduce(sizes, seated, fn size, remaining ->
        {members, rest} = Enum.split(remaining, size)

        circle = %{
          formation_key: formation_key,
          members: Enum.map(members, &elem(&1, 1))
        }

        {circle, rest}
      end)

    {circles, waiting}
  end

  defp allocation(candidate_count, min_size, _max_size) when candidate_count < min_size,
    do: {0, 0}

  defp allocation(candidate_count, min_size, max_size) do
    required_circle_count = ceil_div(candidate_count, max_size)

    if candidate_count >= required_circle_count * min_size do
      {required_circle_count, candidate_count}
    else
      circle_count = required_circle_count - 1
      {circle_count, circle_count * max_size}
    end
  end

  defp preferred_circle_count(0, _min_size, _max_size), do: 0

  defp preferred_circle_count(seated_count, min_size, max_size) do
    target_size = min(max(@target_circle_size, min_size), max_size)
    min_circle_count = ceil_div(seated_count, max_size)
    max_circle_count = div(seated_count, min_size)
    ideal_floor = div(seated_count, target_size)

    [min_circle_count, max_circle_count, ideal_floor, ideal_floor + 1]
    |> Enum.filter(&(&1 >= min_circle_count and &1 <= max_circle_count))
    |> Enum.uniq()
    |> Enum.reduce(nil, fn circle_count, best_count ->
      if closer_to_target?(seated_count, target_size, circle_count, best_count) do
        circle_count
      else
        best_count
      end
    end)
  end

  defp closer_to_target?(_seated_count, _target_size, _circle_count, nil), do: true

  defp closer_to_target?(seated_count, target_size, circle_count, best_count) do
    candidate_error = abs(seated_count - target_size * circle_count)
    best_error = abs(seated_count - target_size * best_count)
    candidate_scaled_error = candidate_error * best_count
    best_scaled_error = best_error * circle_count

    candidate_scaled_error < best_scaled_error or
      (candidate_scaled_error == best_scaled_error and circle_count < best_count)
  end

  defp circle_sizes(0, 0), do: []

  defp circle_sizes(seated_count, circle_count) do
    base_size = div(seated_count, circle_count)
    extra_members = rem(seated_count, circle_count)

    for index <- 0..(circle_count - 1) do
      base_size + if(index < extra_members, do: 1, else: 0)
    end
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
