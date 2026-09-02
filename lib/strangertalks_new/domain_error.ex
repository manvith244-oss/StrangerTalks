defmodule StrangertalksNew.DomainError do
  @moduledoc """
  Authoritative domain error catalog and serialization for StrangerTalks.
  Provides stable, machine-readable error representations across Channels and HTTP.
  """

  @catalog %{
    # Validation
    invalid_request: %{
      code: "INVALID_REQUEST",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 400
    },
    invalid_door_type: %{
      code: "INVALID_DOOR_TYPE",
      category: :validation,
      retryable: false,
      action: :return_to_talk,
      http_status: 400
    },
    language_required: %{
      code: "LANGUAGE_REQUIRED",
      category: :validation,
      retryable: false,
      action: :return_to_talk,
      http_status: 422
    },
    invalid_conversation_language: %{
      code: "INVALID_CONVERSATION_LANGUAGE",
      category: :validation,
      retryable: false,
      action: :return_to_talk,
      http_status: 422
    },
    invalid_payload: %{
      code: "INVALID_PAYLOAD",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 400
    },
    invalid_message_id: %{
      code: "INVALID_MESSAGE_ID",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 400
    },
    invalid_voice_note_id: %{
      code: "INVALID_VOICE_NOTE_ID",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 400
    },
    invalid_voice_duration: %{
      code: "INVALID_VOICE_DURATION",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    media_signature_mismatch: %{
      code: "MEDIA_SIGNATURE_MISMATCH",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    unsupported_media_type: %{
      code: "UNSUPPORTED_MEDIA_TYPE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 415
    },
    message_too_large: %{
      code: "MESSAGE_TOO_LARGE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 413
    },
    voice_note_too_large: %{
      code: "VOICE_NOTE_TOO_LARGE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 413
    },
    view_once_photo_too_large: %{
      code: "VIEW_ONCE_PHOTO_TOO_LARGE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 413
    },
    image_dimension_too_large: %{
      code: "IMAGE_DIMENSION_TOO_LARGE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    metadata_normalization_violation: %{
      code: "METADATA_NORMALIZATION_VIOLATION",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    malformed_image: %{
      code: "MALFORMED_IMAGE",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    invalid_staging_token: %{
      code: "INVALID_STAGING_TOKEN",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 400
    },

    # Authentication & Identity
    invalid_token: %{
      code: "INVALID_TOKEN",
      category: :authentication,
      retryable: false,
      action: :refresh_session,
      http_status: 401
    },
    invalid_participant: %{
      code: "INVALID_PARTICIPANT",
      category: :authentication,
      retryable: false,
      action: :refresh_session,
      http_status: 401
    },
    participant_mismatch: %{
      code: "PARTICIPANT_MISMATCH",
      category: :authentication,
      retryable: false,
      action: :refresh_session,
      http_status: 403
    },
    invalid_session: %{
      code: "INVALID_SESSION",
      category: :authentication,
      retryable: false,
      action: :refresh_session,
      http_status: 401
    },

    # Authorization
    not_conversation_member: %{
      code: "NOT_CONVERSATION_MEMBER",
      category: :authorization,
      retryable: false,
      action: :return_to_talk,
      http_status: 403
    },
    not_message_recipient: %{
      code: "NOT_MESSAGE_RECIPIENT",
      category: :authorization,
      retryable: false,
      action: :none,
      http_status: 403
    },
    sender_cannot_acknowledge: %{
      code: "SENDER_CANNOT_ACKNOWLEDGE",
      category: :authorization,
      retryable: false,
      action: :none,
      http_status: 403
    },

    # Conflict / Current State
    participant_busy: %{
      code: "PARTICIPANT_BUSY",
      category: :conflict,
      retryable: false,
      action: :resume_conversation,
      http_status: 409
    },
    already_queued_different_door: %{
      code: "ALREADY_QUEUED_DIFFERENT_DOOR",
      category: :conflict,
      retryable: false,
      action: :return_to_talk,
      http_status: 409
    },
    stale_attempt: %{
      code: "STALE_ATTEMPT",
      category: :conflict,
      retryable: false,
      action: :reconcile,
      http_status: 409
    },
    invalid_transition: %{
      code: "INVALID_TRANSITION",
      category: :conflict,
      retryable: false,
      action: :return_to_talk,
      http_status: 409
    },
    conversation_terminating: %{
      code: "CONVERSATION_TERMINATING",
      category: :conflict,
      retryable: false,
      action: :return_to_talk,
      http_status: 409
    },
    message_id_conflict: %{
      code: "MESSAGE_ID_CONFLICT",
      category: :conflict,
      retryable: false,
      action: :none,
      http_status: 409
    },
    voice_note_id_conflict: %{
      code: "VOICE_NOTE_ID_CONFLICT",
      category: :conflict,
      retryable: false,
      action: :none,
      http_status: 409
    },
    already_consumed: %{
      code: "ALREADY_CONSUMED",
      category: :conflict,
      retryable: false,
      action: :none,
      http_status: 410
    },

    # Not Found
    conversation_not_found: %{
      code: "CONVERSATION_NOT_FOUND",
      category: :not_found,
      retryable: false,
      action: :return_to_talk,
      http_status: 404
    },
    unknown_message: %{
      code: "UNKNOWN_MESSAGE",
      category: :not_found,
      retryable: false,
      action: :none,
      http_status: 404
    },
    unknown_voice_note: %{
      code: "UNKNOWN_VOICE_NOTE",
      category: :not_found,
      retryable: false,
      action: :none,
      http_status: 404
    },
    target_absent: %{
      code: "TARGET_ABSENT",
      category: :not_found,
      retryable: false,
      action: :none,
      http_status: 404
    },

    # Rate / Capacity
    rate_limited: %{
      code: "RATE_LIMITED",
      category: :rate_limit,
      retryable: true,
      action: :wait,
      http_status: 429
    },
    message_buffer_full: %{
      code: "MESSAGE_BUFFER_FULL",
      category: :rate_limit,
      retryable: true,
      action: :wait,
      http_status: 429
    },
    voice_note_pending_limit: %{
      code: "VOICE_NOTE_PENDING_LIMIT",
      category: :capacity,
      retryable: true,
      action: :wait,
      http_status: 413
    },
    pin_limit_reached: %{
      code: "PIN_LIMIT_REACHED",
      category: :validation,
      retryable: false,
      action: :none,
      http_status: 422
    },
    voice_note_conversation_capacity: %{
      code: "VOICE_NOTE_CONVERSATION_CAPACITY",
      category: :capacity,
      retryable: false,
      action: :none,
      http_status: 413
    },
    voice_note_global_capacity: %{
      code: "VOICE_NOTE_GLOBAL_CAPACITY",
      category: :capacity,
      retryable: true,
      action: :wait,
      http_status: 413
    },
    view_once_sender_unviewed_limit: %{
      code: "VIEW_ONCE_SENDER_UNVIEWED_LIMIT",
      category: :capacity,
      retryable: false,
      action: :none,
      http_status: 413
    },
    view_once_conversation_capacity: %{
      code: "VIEW_ONCE_CONVERSATION_CAPACITY",
      category: :capacity,
      retryable: false,
      action: :none,
      http_status: 413
    },
    view_once_global_capacity: %{
      code: "VIEW_ONCE_GLOBAL_CAPACITY",
      category: :capacity,
      retryable: true,
      action: :wait,
      http_status: 413
    },
    safety_media_capacity_exceeded: %{
      code: "SAFETY_MEDIA_CAPACITY_EXCEEDED",
      category: :capacity,
      retryable: false,
      action: :none,
      http_status: 413
    },
    conversation_busy: %{
      code: "CONVERSATION_BUSY",
      category: :capacity,
      retryable: true,
      action: :wait,
      http_status: 503
    },

    # Transport / Availability
    conversation_unavailable: %{
      code: "CONVERSATION_UNAVAILABLE",
      category: :transport,
      retryable: true,
      action: :reconnect,
      http_status: 503
    },
    media_unavailable: %{
      code: "MEDIA_UNAVAILABLE",
      category: :transport,
      retryable: false,
      action: :none,
      http_status: 410
    },
    capability_invalid_or_expired: %{
      code: "CAPABILITY_INVALID_OR_EXPIRED",
      category: :transport,
      retryable: false,
      action: :none,
      http_status: 410
    },
    reconnection_unavailable: %{
      code: "RECONNECTION_UNAVAILABLE",
      category: :transport,
      retryable: false,
      action: :return_to_talk,
      http_status: 503
    },
    queue_join_failed: %{
      code: "QUEUE_JOIN_FAILED",
      category: :transport,
      retryable: true,
      action: :return_to_talk,
      http_status: 503
    },

    # Internal Fallback
    internal_error: %{
      code: "INTERNAL_ERROR",
      category: :internal,
      retryable: true,
      action: :none,
      http_status: 500
    }
  }

  @doc """
  Builds a standardized error map from an atom or raw term.
  """
  def from_error(term) do
    key = normalize_key(term)

    case Map.get(@catalog, key) do
      nil ->
        %{
          code: "INTERNAL_ERROR",
          category: :internal,
          retryable: true,
          action: :none,
          http_status: 500,
          reason: "internal_error"
        }

      entry ->
        Map.put(entry, :reason, Atom.to_string(key))
    end
  end

  @doc """
  Serializes a domain error for Phoenix Channel reply.
  Maintains backward compatibility with legacy `reason` field while providing
  `code`, `category`, `retryable`, and `action`.
  """
  def to_channel_payload({:rate_limited, retry_after_ms})
      when is_integer(retry_after_ms) and retry_after_ms > 0 do
    :rate_limited
    |> to_channel_payload()
    |> Map.put(:retry_after_ms, retry_after_ms)
  end

  def to_channel_payload(term) do
    error = from_error(term)

    %{
      code: error.code,
      category: Atom.to_string(error.category),
      retryable: error.retryable,
      action: Atom.to_string(error.action),
      reason: error.reason
    }
  end

  @doc """
  Serializes a domain error for HTTP JSON response.
  Returns `{status_code, %{error: %{code: ..., category: ..., retryable: ..., action: ...}}}`.
  """
  def to_http_response({:rate_limited, retry_after_ms})
      when is_integer(retry_after_ms) and retry_after_ms > 0 do
    {status, payload} = to_http_response(:rate_limited)
    {status, put_in(payload, [:error, :retry_after_ms], retry_after_ms)}
  end

  def to_http_response(term) do
    error = from_error(term)

    payload = %{
      error: %{
        code: error.code,
        category: Atom.to_string(error.category),
        retryable: error.retryable,
        action: Atom.to_string(error.action),
        reason: error.reason
      }
    }

    {error.http_status, payload}
  end

  @doc false
  def canonical_code?(code) when is_binary(code) do
    Enum.any?(@catalog, fn {_key, entry} -> entry.code == code end)
  end

  def canonical_code?(_code), do: false

  defp normalize_key({:invalid_transition, _status, _event}), do: :invalid_transition
  defp normalize_key({:rate_limited, _retry_after_ms}), do: :rate_limited
  defp normalize_key(:buffer_overflow_imminent), do: :message_buffer_full
  defp normalize_key(:invalid_queue_parameters), do: :invalid_request
  defp normalize_key(:invalid_message_payload), do: :invalid_payload
  defp normalize_key(:invalid_voice_note_payload), do: :invalid_payload
  defp normalize_key(:invalid_report_payload), do: :invalid_payload
  defp normalize_key(:invalid_report_category), do: :invalid_request
  defp normalize_key(:unsupported_event), do: :invalid_request
  defp normalize_key(:not_voice_note_recipient), do: :not_message_recipient
  defp normalize_key(:conversation_inactive), do: :conversation_unavailable
  defp normalize_key(:upload_in_progress), do: :voice_note_pending_limit
  defp normalize_key(:voice_note_unavailable), do: :conversation_unavailable
  defp normalize_key(atom) when is_atom(atom), do: atom

  defp normalize_key(binary) when is_binary(binary) do
    case String.downcase(binary) do
      "participant_busy" -> :participant_busy
      "invalid_door_type" -> :invalid_door_type
      "queue_join_failed" -> :queue_join_failed
      "already_queued_different_door" -> :already_queued_different_door
      "participant_mismatch" -> :participant_mismatch
      "not_conversation_member" -> :not_conversation_member
      "conversation_not_found" -> :conversation_not_found
      "conversation_unavailable" -> :conversation_unavailable
      "invalid_token" -> :invalid_token
      _ -> :internal_error
    end
  end

  defp normalize_key(_other), do: :internal_error
end
