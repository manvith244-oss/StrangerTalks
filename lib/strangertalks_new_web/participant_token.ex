defmodule StrangertalksNewWeb.ParticipantToken do
  @moduledoc false

  alias StrangertalksNewWeb.Endpoint

  @salt "anonymous participant socket"
  @max_age 60 * 60 * 24 * 30

  def salt, do: @salt
  def max_age, do: @max_age

  def sign(participant_id) do
    Phoenix.Token.sign(Endpoint, @salt, participant_id)
  end

  def sign(participant_id, source_fingerprint)
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 do
    Phoenix.Token.sign(Endpoint, @salt, %{
      v: 2,
      participant_id: participant_id,
      source_fingerprint: source_fingerprint
    })
  end

  def verify(token) do
    case verify_authority(token) do
      {:ok, %{participant_id: participant_id}} -> {:ok, participant_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_authority(token) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok,
       %{v: 2, participant_id: participant_id, source_fingerprint: source_fingerprint}}
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 ->
        {:ok, %{participant_id: participant_id, source_fingerprint: source_fingerprint}}

      {:ok, participant_id} when is_binary(participant_id) ->
        {:ok, %{participant_id: participant_id, source_fingerprint: nil}}

      {:ok, _invalid_payload} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
