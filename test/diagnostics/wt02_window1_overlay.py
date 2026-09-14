from pathlib import Path

path = Path("lib/strangertalks_new/relationship_reconnections.ex")
text = path.read_text()

old = """      {:ok, {:mutual_candidate, _intent}} ->
        complete_mutual_match(relationship, participant_id, door_type)
"""
new = """      {:ok, {:mutual_candidate, _intent}} ->
        wt02_window1_checkpoint()
        complete_mutual_match(relationship, participant_id, door_type)
"""
assert text.count(old) == 1, "mutual-candidate checkpoint site drift"
text = text.replace(old, new, 1)

anchor = "  def cancel(relationship_id, participant_id) do\n"
helper = """  defp wt02_window1_checkpoint do
    case Process.get(:wt02_window1_barrier) do
      {controller, ref} when is_pid(controller) and is_reference(ref) ->
        send(controller, {:wt02_window1_checkpoint, ref, self()})

        receive do
          {:wt02_window1_release, ^ref} -> :ok
        after
          10_000 -> raise "WT02_HARNESS_INVALID checkpoint release timeout"
        end

      _ ->
        :ok
    end
  end

"""
assert text.count(anchor) == 1, "checkpoint helper anchor drift"
path.write_text(text.replace(anchor, helper + anchor, 1))
