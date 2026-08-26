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

  def verify(token) do
    with {:ok, authority} <- Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      verify_authority(authority)
    end
  end

  defp verify_authority({:participant, participant_id, version})
       when is_binary(participant_id) and is_integer(version) do
    if current_version?(participant_id, version),
      do: {:ok, participant_id},
      else: {:error, :stale_participant_credential}
  end

  defp verify_authority({:account_session, participant_id, version, account_session_id})
       when is_binary(participant_id) and is_integer(version) and is_binary(account_session_id) do
    if current_version?(participant_id, version) and
         active_account_session?(account_session_id, participant_id),
      do: {:ok, participant_id},
      else: {:error, :stale_account_session}
  end

  # Legacy anonymous tokens signed before credential versioning remain valid only
  # for participants that have never adopted continuity. The migration advances
  # already-connected participants so old connected credentials fail closed.
  defp verify_authority(participant_id) when is_binary(participant_id) do
    if current_version?(participant_id, 0),
      do: {:ok, participant_id},
      else: {:error, :stale_participant_credential}
  end

  defp verify_authority(_), do: {:error, :invalid_participant_credential}

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
