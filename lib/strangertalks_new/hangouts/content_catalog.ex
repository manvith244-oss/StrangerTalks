defmodule StrangertalksNew.Hangouts.ContentCatalog do
  @neutral_items [
    %{
      id: "und/question-small-joy",
      kind: :QUESTION,
      language_tag: "und",
      source: :FIRST_PARTY,
      safety_status: :APPROVED,
      publication_status: :ACTIVE,
      body: "What is one tiny thing that made your day better?"
    },
    %{
      id: "und/poll-plan-vs-spontaneous",
      kind: :POLL,
      language_tag: "und",
      source: :FIRST_PARTY,
      safety_status: :APPROVED,
      publication_status: :ACTIVE,
      body: "Which sounds more like you?",
      options: ["Plan it", "Figure it out as I go"]
    },
    %{
      id: "und/question-unpopular-simple",
      kind: :QUESTION,
      language_tag: "und",
      source: :FIRST_PARTY,
      safety_status: :APPROVED,
      publication_status: :ACTIVE,
      body: "What harmless opinion would you defend way too seriously?"
    }
  ]

  @localized_items %{
    "en" => [
      %{
        id: "en/question-perfect-free-hour",
        kind: :QUESTION,
        language_tag: "en",
        source: :FIRST_PARTY,
        safety_status: :APPROVED,
        publication_status: :ACTIVE,
        body: "You suddenly get one completely free hour. What do you do with it?"
      }
    ]
  }

  def items(language_tag) when is_binary(language_tag) do
    localized = Map.get(@localized_items, language_tag, [])
    localized ++ @neutral_items
  end

  def items(_language_tag), do: []

  def fetch(id) when is_binary(id) do
    @localized_items
    |> Map.values()
    |> List.flatten()
    |> Kernel.++(@neutral_items)
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> {:error, :unknown_content}
      item -> {:ok, item}
    end
  end

  def fetch(_id), do: {:error, :unknown_content}
end
