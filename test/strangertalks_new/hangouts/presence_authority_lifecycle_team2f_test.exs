defmodule StrangertalksNew.Hangouts.PresenceAuthorityLifecycleTeam2FTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias StrangertalksNew.Hangouts
  alias StrangertalksNew.Hangouts.{PresenceAuthority, RoomServer}
  alias StrangertalksNew.{Participants, Repo}

  @ledger :strangertalks_hangout_presence_crash_ledger

  setup do
    original = Application.get_env(:strangertalks_new, :hangouts_public_beta_enabled)
    Application.put_env(:strangertalks_new, :hangouts_public_beta_enabled, true)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:strangertalks_new, :hangouts_public_beta_enabled)
      else
        Application.put_env(:strangertalks_new, :hangouts_public_beta_enabled, original)
      end
    end)

    :ok
  end

  test "authority restart tolerates sandbox owner exit and replays ledger only after DB recovery" do
    # Independent owner represents the short-lived test process whose sandbox closes.
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> if Process.alive?(owner), do: Sandbox.stop_owner(owner) end)

    members =
      for _ <- 1..3 do
        {:ok, participant} = Participants.create_participant(%{})
        participant
      end

    {:ok, %{room: room}} =
      Hangouts.create_formed_room(
        Enum.map(members, & &1.participant_id),
        %{
          language_tag: "en",
          experiment_arm: :GROUP_WITH_CONTENT,
          minimum_size: 3,
          target_size: 4,
          max_size: 6
        }
      )

    [participant | _] = members
    {:ok, _pid} = RoomServer.ensure_started(room.room_id)
    on_exit(fn ->
      case RoomServer.lookup(room.room_id) do
        {:ok, pid} -> Process.exit(pid, :shutdown)
        _ -> :ok
      end
    end)

    test_pid = self()
    channel_pid =
      spawn(fn ->
        send(test_pid, {:registered, self(),
          PresenceAuthority.register(room.room_id, participant.participant_id, Ecto.UUID.generate())})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:registered, ^channel_pid, :ok}, 1_000
    authority_pid = Process.whereis(PresenceAuthority)
    assert is_pid(authority_pid)
    assert [{^channel_pid, _, _, _}] = :ets.lookup(@ledger, channel_pid)

    # Hold the authority at a deterministic mailbox barrier, then remove both
    # the channel and the SQL sandbox owner before resuming its durable-disconnect.
    :ok = :sys.suspend(authority_pid)
    channel_ref = Process.monitor(channel_pid)
    Process.exit(channel_pid, :kill)
    assert_receive {:DOWN, ^channel_ref, :process, ^channel_pid, :killed}, 1_000
    :ok = Sandbox.stop_owner(owner)
    :ok = :sys.resume(authority_pid)
    _ = :sys.get_state(authority_pid)

    # Any database-unavailable path must retain the stale key rather than
    # inventing a successful durable disconnection.
    assert [{^channel_pid, _, _, _}] = :ets.lookup(@ledger, channel_pid)

    # Restart the real supervised authority while the owner is still absent:
    # ETS transfers to the application supervisor. The new authority must not
    # crash-loop in init/1 or destroy its outstanding crash-ledger evidence.
    monitor = Process.monitor(authority_pid)
    Process.exit(authority_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^authority_pid, :killed}, 2_000

    successor = await_restarted_authority(authority_pid)
    assert {:error, :presence_authority_recovering} =
             PresenceAuthority.register(room.room_id, participant.participant_id, Ecto.UUID.generate())

    assert Process.whereis(StrangertalksNew.Repo) != nil
    assert [{^channel_pid, _, _, _}] = :ets.lookup(@ledger, channel_pid)

    # Restore an independent sandbox owner; previously durable ACTIVE member
    # must eventually be disconnected without crashing unrelated application services.
    replacement_owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> if Process.alive?(replacement_owner), do: Sandbox.stop_owner(replacement_owner) end)

    assert eventually(fn -> :ets.lookup(@ledger, channel_pid) == [] end)
    assert {:ok, snapshot} = RoomServer.snapshot(room.room_id, participant.participant_id)
    assert Enum.any?(snapshot.members, fn member ->
      member.self and member.status == :DISCONNECTED
    end)
    assert Process.whereis(PresenceAuthority) == successor
    assert is_pid(Process.whereis(StrangertalksNew.Repo))
    assert :ok =
             PresenceAuthority.register(room.room_id, participant.participant_id, Ecto.UUID.generate())

    assert :ok = PresenceAuthority.unregister(room.room_id, participant.participant_id)
  end

  defp await_restarted_authority(previous, tries \\ 40)
  defp await_restarted_authority(_previous, 0), do: flunk("PresenceAuthority did not restart")

  defp await_restarted_authority(previous, tries) do
    case Process.whereis(PresenceAuthority) do
      pid when is_pid(pid) and pid != previous -> pid
      _ ->
        receive do
        after
          20 -> await_restarted_authority(previous, tries - 1)
        end
    end
  end

  defp eventually(predicate, tries \\ 100)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, tries) do
    if predicate.() do
      true
    else
      receive do
      after
        20 -> eventually(predicate, tries - 1)
      end
    end
  end
end
