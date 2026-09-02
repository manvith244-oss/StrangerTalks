defmodule StrangertalksNew.T05ViewReachableCapacityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp create_conversation(sender_id, recipient_id) do
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: sender_id,
        participant_b_id: recipient_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: matching.match_id,
        participant_a_id: sender_id,
        participant_b_id: recipient_id,
        conversation_status: :ACTIVE,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    {:ok, pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})
    {conversation.conversation_id, pid}
  end

  defp stage_video(conversation_id, sender_id, client_message_id, binary) do
    metadata = %{
      media_type: "video/mp4",
      width: 16,
      height: 16,
      duration_seconds: 1.0,
      content_hash: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    }

    {:ok, staging_token} =
      ViewOnceMediaStore.stage_media(conversation_id, sender_id, binary, metadata)

    assert {:ok, sent} =
             ConversationServer.append_view_once_video(
               conversation_id,
               sender_id,
               client_message_id,
               staging_token,
               1
             )

    assert sent.views_remaining == 1
    sent
  end

  test "T05-VIEW-002 abuse/resource: authenticated opens can occupy the global video presentation budget until capability release" do
    {:ok, recipient} = StrangertalksNew.Participants.create_participant(%{})
    recipient_id = recipient.participant_id
    video = :binary.copy(<<0xAB>>, 1024)
    video_bytes = byte_size(video)
    previous_limit = Application.get_env(:strangertalks_new, :view_once_presentation_reservation_limit)

    fixtures =
      for n <- 1..3 do
        {:ok, sender} = StrangertalksNew.Participants.create_participant(%{})
        {conversation_id, pid} = create_conversation(sender.participant_id, recipient_id)
        client_message_id = Ecto.UUID.generate()
        stage_video(conversation_id, sender.participant_id, client_message_id, video)

        %{
          n: n,
          conversation_id: conversation_id,
          pid: pid,
          sender_id: sender.participant_id,
          client_message_id: client_message_id
        }
      end

    baseline = ViewOnceMediaStore.inspect_state().presentation_reserved_bytes

    Application.put_env(
      :strangertalks_new,
      :view_once_presentation_reservation_limit,
      baseline + video_bytes * 2
    )

    on_exit(fn ->
      Enum.each(fixtures, fn fixture ->
        ViewOnceMediaStore.delete_conversation(fixture.conversation_id)
        if Process.alive?(fixture.pid), do: Process.exit(fixture.pid, :normal)
      end)

      if is_nil(previous_limit) do
        Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)
      else
        Application.put_env(
          :strangertalks_new,
          :view_once_presentation_reservation_limit,
          previous_limit
        )
      end
    end)

    [first, second, third] = fixtures

    assert {:ok, open_1} =
             ConversationServer.open_view_once_video(
               first.conversation_id,
               recipient_id,
               first.client_message_id,
               "capacity-open-1"
             )

    assert {:ok, open_2} =
             ConversationServer.open_view_once_video(
               second.conversation_id,
               recipient_id,
               second.client_message_id,
               "capacity-open-2"
             )

    full = ViewOnceMediaStore.inspect_state()
    assert full.presentation_reserved_bytes == baseline + video_bytes * 2
    assert full.capabilities_count == 2

    assert {:error, :presentation_capacity_unavailable} =
             ConversationServer.open_view_once_video(
               third.conversation_id,
               recipient_id,
               third.client_message_id,
               "capacity-open-3"
             )

    assert {:ok, third_messages} =
             ConversationServer.get_messages_after(third.conversation_id, recipient_id, 0)

    third_message =
      Enum.find(third_messages.messages, &(&1.client_message_id == third.client_message_id))

    assert third_message.views_remaining == 1
    assert third_message.views_consumed == 0
    assert third_message.view_once_state == "unviewed"

    store_pid = Process.whereis(ViewOnceMediaStore)
    send(store_pid, {:expire_capability, open_1.presentation_token})
    _ = :sys.get_state(store_pid)

    after_release = ViewOnceMediaStore.inspect_state()
    assert after_release.presentation_reserved_bytes == baseline + video_bytes
    assert after_release.capabilities_count == 1

    assert {:ok, open_3} =
             ConversationServer.open_view_once_video(
               third.conversation_id,
               recipient_id,
               third.client_message_id,
               "capacity-open-3"
             )

    assert is_binary(open_3.presentation_token)
    assert ViewOnceMediaStore.inspect_state().presentation_reserved_bytes ==
             baseline + video_bytes * 2

    assert is_binary(open_2.presentation_token)
  end
end
