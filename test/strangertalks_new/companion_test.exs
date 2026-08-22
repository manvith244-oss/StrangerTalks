defmodule StrangertalksNew.CompanionTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Companion, Conversation, MatchingRules, Message, Repo}

  defmodule FakeProvider do
    @behaviour StrangertalksNew.Companion.Provider

    @impl true
    def generate(context) do
      if pid = Application.get_env(:strangertalks_new, :companion_test_pid) do
        send(pid, {:companion_context, context})
      end

      case Application.get_env(:strangertalks_new, :companion_test_mode, :assist) do
        :stale ->
          conversation = Repo.get!(Conversation, context.conversation_id)

          conversation
          |> Ecto.Changeset.change(
            conversation_status: :ENDED,
            ended_at: DateTime.utc_now(),
            ending_type: :NATURAL_END,
            ending_initiator: context.participant_id
          )
          |> Repo.update!()

          assist_result()

        :decline ->
          {:ok,
           %{
             decision: :decline,
             reason: "I can’t help pressure someone into responding.",
             suggestions: [],
             model: "fake-companion"
           }}

        _ ->
          assist_result()
      end
    end

    defp assist_result do
      {:ok,
       %{
         decision: :assist,
         reason: nil,
         suggestions: [
           %{style: "Warm", text: "I get what you mean. What made you think about that?"},
           %{style: "Light", text: "Okay, now I’m curious — what happened next?"}
         ],
         model: "fake-companion"
       }}
    end
  end

  setup do
    previous_companion = Application.get_env(:strangertalks_new, :companion)
    previous_pid = Application.get_env(:strangertalks_new, :companion_test_pid)
    previous_mode = Application.get_env(:strangertalks_new, :companion_test_mode)

    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      provider: FakeProvider
    )

    Application.put_env(:strangertalks_new, :companion_test_pid, self())
    Application.put_env(:strangertalks_new, :companion_test_mode, :assist)

    on_exit(fn ->
      restore_env(:companion, previous_companion)
      restore_env(:companion_test_pid, previous_pid)
      restore_env(:companion_test_mode, previous_mode)
    end)

    conversation_fixture("en")
  end

  test "explicit request gets bounded suggestions without creating a participant message", context do
    insert_message(context, context.participant_b, 1, "I started learning guitar last week.")
    update_message_count(context.conversation, 1)

    assert {:ok, result} =
             Companion.request(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "respond",
               "request" => "Help me reply naturally",
               "draft" => "",
               "tone" => "warm"
             })

    assert result.status == "ready"
    assert result.language == "en"
    assert result.mode == "respond"
    assert length(result.suggestions) == 2
    assert result.model == "fake-companion"
    assert Repo.aggregate(Message, :count) == 1

    assert_receive {:companion_context, captured}
    assert captured.language == "en"
    assert captured.messages == [%{role: "stranger", text: "I started learning guitar last week.", sequence: 1}]
    refute Map.has_key?(StrangertalksNew.Companion.Context.public_context(captured), :participant_id)
    refute Map.has_key?(StrangertalksNew.Companion.Context.public_context(captured), :peer_id)
  end

  test "result is discarded when Conversation authority changes during model generation", context do
    Application.put_env(:strangertalks_new, :companion_test_mode, :stale)

    assert {:error, :companion_stale} =
             Companion.request(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "continue",
               "tone" => "natural"
             })

    assert_receive {:companion_context, _captured}
  end

  test "terminal block authority prevents Companion generation", context do
    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(
               context.conversation.conversation_id,
               context.participant_a
             )

    assert {:error, :conversation_unavailable} =
             Companion.request(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "continue"
             })

    refute_receive {:companion_context, _captured}, 20
  end

  test "a non-member cannot ask the Companion about another Conversation", context do
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})

    assert {:error, :not_conversation_member} =
             Companion.request(context.conversation.conversation_id, outsider.participant_id, %{
               "mode" => "respond",
               "request" => "What should I say?"
             })

    refute_receive {:companion_context, _captured}, 20
  end

  test "unsupported pseudo-psychology modes never reach the model", context do
    assert {:error, :invalid_payload} =
             Companion.request(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "infer_attachment",
               "request" => "Tell me what they secretly feel"
             })

    refute_receive {:companion_context, _captured}, 20
  end

  test "provider may safely decline manipulative assistance", context do
    Application.put_env(:strangertalks_new, :companion_test_mode, :decline)

    assert {:ok, %{status: "declined", suggestions: [], reason: reason}} =
             Companion.request(context.conversation.conversation_id, context.participant_a, %{
               "mode" => "respond",
               "request" => "Help me pressure them to reply"
             })

    assert is_binary(reason)
  end

  defp insert_message(context, sender_id, sequence, content) do
    Repo.insert!(
      Message.changeset(%Message{}, %{
        conversation_id: context.conversation.conversation_id,
        sender_id: sender_id,
        content: content,
        expected_sequence_id: sequence,
        created_at: DateTime.utc_now()
      })
    )
  end

  defp update_message_count(conversation, count) do
    conversation
    |> Ecto.Changeset.change(message_count: count, last_message_timestamp: DateTime.utc_now())
    |> Repo.update!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)

  defp conversation_fixture(language) do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_language: language,
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
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :PENDING,
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

    %{
      match: match,
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
