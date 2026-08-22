defmodule StrangertalksNew.Companion.Provider do
  @moduledoc """
  Provider boundary for A01 Conversation Companion.

  Providers receive only the already-bounded Companion context. They do not receive
  repository, queue, safety, relationship, or message-send capabilities.
  """

  @type suggestion :: %{style: String.t(), text: String.t()}
  @type result :: %{
          decision: :assist | :decline,
          reason: String.t() | nil,
          suggestions: [suggestion()],
          model: String.t() | nil
        }

  @callback generate(map()) :: {:ok, result()} | {:error, term()}
end
