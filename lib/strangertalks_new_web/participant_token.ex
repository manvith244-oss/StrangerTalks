defmodule StrangertalksNewWeb.ParticipantToken do
  @moduledoc false

  import Ecto.Query

  alias StrangertalksNew.Accounts.{AccountSession, PrivateAccount}
  alias StrangertalksNew.{Participant, Repo}
  alias StrangertalksNewWeb.Endpoint

  @salt "anonymous participant socket"
  @max_age 60 * 60 * 24 * 30

  def salt, do: @salt
  def max_age, do: @max_age

  def sign(participant_id) do
    Phoenix.Token.sign(
      Endpoint,
      @salt,
      {:participant, participant_id, credential_version(participant_id)}
    )
  end

  def sign_account_session(%AccountSession{
        account: %PrivateAccount{participant_id: participant_id},
        account_session_id: account_session_id
      }) do
    Phoenix.Token.sign(
      Endpoint,
      @salt,
      {:account_session, participant_id, credential_version(participant_id), account_session_id}
    )
  end

  def sign(participant_id, source_fingerprint)
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 do
    Phoenix.Token.sign(Endpoint, @salt, %{
      v: 3,
      participant_id: participant_id,
      source_fingerprint: source_fingerprint,
      credential_version: credential_version(participant_id)
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
       %{
         v: 3,
         participant_id: participant_id,
         source_fingerprint: source_fingerprint,
         credential_version: version
       }}
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 and is_integer(version) ->
        if current_version?(participant_id, version),
          do: {:ok, %{participant_id: participant_id, source_fingerprint: source_fingerprint}},
          else: {:error, :stale_participant_credential}

      {:ok, %{v: 2, participant_id: participant_id, source_fingerprint: source_fingerprint}}
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 ->
        if current_version?(participant_id, 0),
          do: {:ok, %{participant_id: participant_id, source_fingerprint: source_fingerprint}},
          else: {:error, :stale_participant_credential}

      {:ok, {:participant, participant_id, version}}
      when is_binary(participant_id) and is_integer(version) ->
        if current_version?(participant_id, version),
          do: {:ok, %{participant_id: participant_id, source_fingerprint: nil}},
          else: {:error, :stale_participant_credential}

      {:ok, {:account_session, participant_id, version, account_session_id}}
      when is_binary(participant_id) and is_integer(version) and is_binary(account_session_id) ->
        if current_version?(participant_id, version) and
             active_account_session?(account_session_id, participant_id),
           do:
             {:ok,
              %{
                participant_id: participant_id,
                source_fingerprint: nil,
                account_session_id: account_session_id
              }},
           else: {:error, :stale_account_session}

      {:ok, participant_id} when is_binary(participant_id) ->
        if current_version?(participant_id, 0),
          do: {:ok, %{participant_id: participant_id, source_fingerprint: nil}},
          else: {:error, :stale_participant_credential}

      {:ok, _invalid_payload} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credential_version(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{credential_version: version} when is_integer(version) -> version
      _ -> 0
    end
  end

  defp current_version?(participant_id, version) do
    Repo.exists?(
      from p in Participant,
        where: p.participant_id == ^participant_id and p.credential_version == ^version
    )
  end

  defp active_account_session?(account_session_id, participant_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from s in AccountSession,
        join: a in PrivateAccount,
        on: a.account_id == s.account_id,
        where:
          s.account_session_id == ^account_session_id and a.participant_id == ^participant_id and
            is_nil(s.revoked_at) and s.expires_at > ^now
    )
  end
end
