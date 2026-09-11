defmodule StrangertalksNew.Experiments.Hearth.Notifier do
  @pubsub StrangertalksNew.PubSub

  def notify({:hearth_bridge_expired, bridge_id, participants}) do
    Enum.each(participants, fn participant_id ->
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(participant_id),
        {:hearth_bridge_expired, bridge_id}
      )
    end)

    :ok
  end

  def notify({:hearth_waiting_expired, participant_id}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(participant_id),
      :hearth_waiting_expired
    )

    :ok
  end

  def notify(_event), do: :ok

  defp topic(participant_id), do: "hearth:#{participant_id}"
end
