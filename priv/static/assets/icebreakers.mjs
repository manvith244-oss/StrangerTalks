export const ICEBREAKER_CATALOG = Object.freeze([
  Object.freeze({id: "en/ocean-or-space", language: "en", text: "Would you rather explore the ocean or outer space?"}),
  Object.freeze({id: "en/tiny-smile-story", language: "en", text: "Tell a tiny story about something that made you smile recently."}),
  Object.freeze({id: "en/instant-skill", language: "en", text: "If you could instantly master one harmless skill, what would it be?"}),
  Object.freeze({id: "en/new-city-afternoon", language: "en", text: "Imagine you both have a free afternoon in a new city—where do you start?"}),
  Object.freeze({id: "en/small-comfort", language: "en", text: "What’s a small comfort you think more people should know about?"}),
  Object.freeze({id: "en/ordinary-meaning", language: "en", text: "What’s something ordinary that means more to you than people might guess?"}),
  Object.freeze({id: "en/conversation-direction", language: "en", text: "Would you rather keep things light, swap stories, or talk about something meaningful?"}),
  Object.freeze({id: "te/ocean-or-space", language: "te", text: "మీరు సముద్రాన్ని అన్వేషించాలనుకుంటారా, లేక అంతరిక్షాన్ని?"}),
  Object.freeze({id: "te/tiny-smile-story", language: "te", text: "ఇటీవల మీకు చిరునవ్వు తెప్పించిన చిన్న విషయం గురించి ఒక చిన్న కథ చెప్పండి."}),
  Object.freeze({id: "te/instant-skill", language: "te", text: "హానికరం కాని ఒక నైపుణ్యాన్ని వెంటనే నేర్చుకోగలిగితే, ఏదిని ఎంచుకుంటారు?"}),
  Object.freeze({id: "te/new-city-afternoon", language: "te", text: "మీ ఇద్దరికీ కొత్త నగరంలో ఖాళీ మధ్యాహ్నం ఉందని ఊహించండి—ఎక్కడి నుంచి మొదలుపెడతారు?"}),
  Object.freeze({id: "te/small-comfort", language: "te", text: "మరింత మంది తెలుసుకోవాలని మీరు అనుకునే చిన్న సాంత్వన ఏమిటి?"}),
  Object.freeze({id: "te/ordinary-meaning", language: "te", text: "సాధారణంగా కనిపించినా, మీకు ఊహించినదానికంటే ఎక్కువ అర్థం కలిగిన విషయం ఏమిటి?"}),
  Object.freeze({id: "te/conversation-direction", language: "te", text: "మాటలను తేలికగా ఉంచాలా, కథలు పంచుకోవాలా, లేక అర్థవంతమైన విషయం గురించి మాట్లాడాలా?"}),
  Object.freeze({id: "hi/ocean-or-space", language: "hi", text: "आप समुद्र की खोज करना चाहेंगे या अंतरिक्ष की?"}),
  Object.freeze({id: "hi/tiny-smile-story", language: "hi", text: "हाल ही में किसी छोटी-सी बात ने आपको मुस्कुराया हो, उसकी एक छोटी कहानी बताइए।"}),
  Object.freeze({id: "hi/instant-skill", language: "hi", text: "अगर आप तुरंत कोई एक सुरक्षित कौशल सीख सकते, तो वह क्या होता?"}),
  Object.freeze({id: "hi/new-city-afternoon", language: "hi", text: "मान लीजिए आप दोनों के पास किसी नए शहर में एक खाली दोपहर है—आप कहाँ से शुरुआत करेंगे?"}),
  Object.freeze({id: "hi/small-comfort", language: "hi", text: "ऐसी कौन-सी छोटी-सी चीज़ है जो आपको सुकून देती है और जिसे अधिक लोगों को जानना चाहिए?"}),
  Object.freeze({id: "hi/ordinary-meaning", language: "hi", text: "ऐसी कौन-सी साधारण चीज़ है जिसका आपके लिए लोगों की अपेक्षा से ज़्यादा महत्व है?"}),
  Object.freeze({id: "hi/conversation-direction", language: "hi", text: "आप बातचीत हल्की रखना चाहेंगे, कहानियाँ बाँटना चाहेंगे, या किसी अर्थपूर्ण विषय पर बात करना चाहेंगे?"})
])

const ICEBREAKER_BY_ID = new Map(ICEBREAKER_CATALOG.map((item) => [item.id, item]))

export function approvedIcebreaker(identity) {
  return typeof identity === "string" ? ICEBREAKER_BY_ID.get(identity) || null : null
}

export function initialIcebreakerState() {
  return {canonicalStatus: "unavailable", identity: null, localDismissed: false}
}

export function applyIcebreakerSnapshot(state, snapshot) {
  const current = state || initialIcebreakerState()

  if (snapshot?.status === "retired") {
    return {canonicalStatus: "retired", identity: null, localDismissed: current.localDismissed}
  }

  const approved = snapshot?.status === "active" ? approvedIcebreaker(snapshot.identity) : null
  if (!approved) {
    return {canonicalStatus: "unavailable", identity: null, localDismissed: current.localDismissed}
  }

  return {canonicalStatus: "active", identity: approved.id, localDismissed: current.localDismissed}
}

export function dismissIcebreaker(state) {
  const current = state || initialIcebreakerState()
  if (current.canonicalStatus !== "active" || current.localDismissed) return current
  return {...current, localDismissed: true}
}

export function resetIcebreakerState() {
  return initialIcebreakerState()
}

export function visibleIcebreaker(state) {
  if (state?.canonicalStatus !== "active" || state.localDismissed) return null
  return approvedIcebreaker(state.identity)
}
