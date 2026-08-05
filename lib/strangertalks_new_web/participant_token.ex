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

  def verify(token) do
    Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)
  end
end
