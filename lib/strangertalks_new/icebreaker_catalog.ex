defmodule StrangertalksNew.IcebreakerCatalog do
  @moduledoc """
  Bounded, first-party Conversation Start catalog.

  The one-argument `identity_for/1` is the runtime authority. It derives the
  Conversation Language from the persisted Match attached to the Conversation
  and returns a language-qualified approved identity. Missing or invalid
  language fails closed: no English or client-side fallback is selected.
  """

  alias StrangertalksNew.{Conversation, ConversationLanguages, Matching, Repo}

  @languages ~w(en te hi)
  @base_identities [
    "ocean-or-space",
    "tiny-smile-story",
    "instant-skill",
    "new-city-afternoon",
    "small-comfort",
    "ordinary-meaning",
    "conversation-direction"
  ]

  @localized_text %{
    "en" => %{
      "ocean-or-space" => "Would you rather explore the ocean or outer space?",
      "tiny-smile-story" => "Tell a tiny story about something that made you smile recently.",
      "instant-skill" => "If you could instantly master one harmless skill, what would it be?",
      "new-city-afternoon" =>
        "Imagine you both have a free afternoon in a new city—where do you start?",
      "small-comfort" => "What’s a small comfort you think more people should know about?",
      "ordinary-meaning" =>
        "What’s something ordinary that means more to you than people might guess?",
      "conversation-direction" =>
        "Would you rather keep things light, swap stories, or talk about something meaningful?"
    },
    "te" => %{
      "ocean-or-space" => "మీరు సముద్రాన్ని అన్వేషించాలనుకుంటారా, లేక అంతరిక్షాన్ని?",
      "tiny-smile-story" =>
        "ఇటీవల మీకు చిరునవ్వు తెప్పించిన చిన్న విషయం గురించి ఒక చిన్న కథ చెప్పండి.",
      "instant-skill" =>
        "హానికరం కాని ఒక నైపుణ్యాన్ని వెంటనే నేర్చుకోగలిగితే, ఏదిని ఎంచుకుంటారు?",
      "new-city-afternoon" =>
        "మీ ఇద్దరికీ కొత్త నగరంలో ఖాళీ మధ్యాహ్నం ఉందని ఊహించండి—ఎక్కడి నుంచి మొదలుపెడతారు?",
      "small-comfort" => "మరింత మంది తెలుసుకోవాలని మీరు అనుకునే చిన్న సాంత్వన ఏమిటి?",
      "ordinary-meaning" =>
        "సాధారణంగా కనిపించినా, మీకు ఊహించినదానికంటే ఎక్కువ అర్థం కలిగిన విషయం ఏమిటి?",
      "conversation-direction" =>
        "మాటలను తేలికగా ఉంచాలా, కథలు పంచుకోవాలా, లేక అర్థవంతమైన విషయం గురించి మాట్లాడాలా?"
    },
    "hi" => %{
      "ocean-or-space" => "आप समुद्र की खोज करना चाहेंगे या अंतरिक्ष की?",
      "tiny-smile-story" =>
        "हाल ही में किसी छोटी-सी बात ने आपको मुस्कुराया हो, उसकी एक छोटी कहानी बताइए।",
      "instant-skill" =>
        "अगर आप तुरंत कोई एक सुरक्षित कौशल सीख सकते, तो वह क्या होता?",
      "new-city-afternoon" =>
        "मान लीजिए आप दोनों के पास किसी नए शहर में एक खाली दोपहर है—आप कहाँ से शुरुआत करेंगे?",
      "small-comfort" =>
        "ऐसी कौन-सी छोटी-सी चीज़ है जो आपको सुकून देती है और जिसे अधिक लोगों को जानना चाहिए?",
      "ordinary-meaning" =>
        "ऐसी कौन-सी साधारण चीज़ है जिसका आपके लिए लोगों की अपेक्षा से ज़्यादा महत्व है?",
      "conversation-direction" =>
        "आप बातचीत हल्की रखना चाहेंगे, कहानियाँ बाँटना चाहेंगे, या किसी अर्थपूर्ण विषय पर बात करना चाहेंगे?"
    }
  }

  @items (
           for {language, localized} <- @localized_text,
               {base_identity, text} <- localized,
               into: %{} do
             {"#{language}/#{base_identity}", %{language: language, text: text}}
           end
         )

  def identity_for(conversation_id) when is_binary(conversation_id) do
    with %Conversation{match_id: match_id} <- Repo.get(Conversation, conversation_id),
         %Matching{conversation_language: language} <- Repo.get(Matching, match_id),
         {:ok, normalized_language} <- ConversationLanguages.normalize(language) do
      identity_for(conversation_id, normalized_language)
    else
      _ -> nil
    end
  end

  def identity_for(_conversation_id), do: nil

  def identity_for(conversation_id, language) when is_binary(conversation_id) do
    with {:ok, normalized_language} <- ConversationLanguages.normalize(language) do
      base_identity =
        Enum.at(@base_identities, :erlang.phash2(conversation_id, length(@base_identities)))

      "#{normalized_language}/#{base_identity}"
    else
      _ -> nil
    end
  end

  def fetch(identity) when is_binary(identity) do
    case Map.fetch(@items, identity) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :unknown_identity}
    end
  end

  def fetch(_identity), do: {:error, :unknown_identity}

  def approved?(identity), do: match?({:ok, _item}, fetch(identity))

  def identities do
    @items
    |> Map.keys()
    |> Enum.sort()
  end

  def identities(language) do
    case ConversationLanguages.normalize(language) do
      {:ok, normalized_language} ->
        Enum.map(@base_identities, &"#{normalized_language}/#{&1}")

      _ ->
        []
    end
  end

  def languages, do: @languages
end
