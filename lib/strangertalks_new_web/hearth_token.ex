defmodule StrangertalksNewWeb.HearthToken do
  @moduledoc false

  alias StrangertalksNewWeb.Endpoint

  @salt "hearth h01a participant socket"
  @max_age 60 * 60 * 4

  def sign(participant_id, source_fingerprint)
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 do
    Phoenix.Token.sign(Endpoint, @salt, %{
      v: 1,
      participant_id: participant_id,
      source_fingerprint: source_fingerprint
    })
  end

  def verify_authority(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok,
       %{
         v: 1,
         participant_id: participant_id,
         source_fingerprint: source_fingerprint
       }}
      when is_binary(participant_id) and is_binary(source_fingerprint) and
             byte_size(source_fingerprint) == 32 ->
        {:ok, %{participant_id: participant_id, source_fingerprint: source_fingerprint}}

      {:ok, _invalid} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_authority(_token), do: {:error, :invalid}
end
