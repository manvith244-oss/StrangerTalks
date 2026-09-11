defmodule StrangertalksNewWeb.HearthH01aSingleShotBoundaryTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Experiments.Hearth.Authority
  alias StrangertalksNew.Participants
  alias StrangertalksNewWeb.{HearthChannel, ParticipantToken, UserSocket}

  setup do
    previous = Application.get_env(:strangertalks_new, :experiment_hearth_enabled, false)
    Application.put_env(:strangertalks_new, :experiment_hearth_enabled, true)

    on_exit(fn ->
      Application.put_env(:strangertalks_new, :experiment_hearth_enabled, previous)
    end)

    :ok
  end

  test "treatment re-entry receives an explicit non-crashing already_participated rejection" do
    participant = participant!()
    {:ok, _reply, socket} = join_hearth(participant)

    first_ref = push(socket, "hearth:submit", %{"contribution" => "Air fryer"})
    assert_reply first_ref, :ok, %{status: "waiting"}
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(Authority, participant.participant_id)

    retry_ref = push(socket, "hearth:submit", %{"contribution" => "Kindle"})
    assert_reply retry_ref, :error, %{reason: "already_participated"}
  end

  test "control re-entry receives an explicit non-crashing already_participated rejection" do
    participant = participant_for_variant!(:control)
    {:ok, _reply, socket} = join_auto(participant)

    first_ref = push(socket, "control:connect", %{})
    assert_reply first_ref, :ok, %{status: "waiting"}
    assert {:ok, %{status: :waiting_removed}} = Authority.disconnect(Authority, participant.participant_id)

    retry_ref = push(socket, "control:connect", %{})
    assert_reply retry_ref, :error, %{reason: "already_participated"}
  end

  test "lab client terminalizes consumed attempts instead of inviting another encounter" do
    source = File.read!("priv/static/assets/hearth_lab.mjs")

    assert source =~ "finishParticipation"
    assert source =~ ~s(error?.reason === "already_participated")
    refute source =~ "You can try again."
    refute source =~ "The next encounter starts clean."
  end

  defp join_hearth(participant) do
    subscribe_and_join(
      connected_socket(participant),
      HearthChannel,
      "hearth:#{participant.participant_id}",
      %{}
    )
  end

  defp join_auto(participant) do
    subscribe_and_join(
      connected_socket(participant),
      HearthChannel,
      "hearth:#{participant.participant_id}",
      %{"variant" => "auto"}
    )
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp participant_for_variant!(variant, attempts \\ 30)

  defp participant_for_variant!(variant, attempts) when attempts > 0 do
    participant = participant!()

    if HearthChannel.assigned_variant(participant.participant_id) == variant do
      participant
    else
      participant_for_variant!(variant, attempts - 1)
    end
  end

  defp participant_for_variant!(variant, 0),
    do: flunk("could not issue a participant assigned to #{inspect(variant)}")
end
