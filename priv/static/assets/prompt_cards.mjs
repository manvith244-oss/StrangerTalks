export const PROMPT_CATEGORIES = Object.freeze([
  Object.freeze({id: "start", label: "Start"}),
  Object.freeze({id: "continue", label: "Continue"}),
  Object.freeze({id: "recover", label: "Recover"})
])

export const PROMPT_CATALOG = Object.freeze([
  Object.freeze({id: "start-1", categoryId: "start", text: "What’s something you’ve been thinking about lately?"}),
  Object.freeze({id: "start-2", categoryId: "start", text: "What kind of day are you having so far?"}),
  Object.freeze({id: "start-3", categoryId: "start", text: "What’s something you could talk about for hours?"}),
  Object.freeze({id: "start-4", categoryId: "start", text: "What’s one small thing that made your day better recently?"}),
  Object.freeze({id: "continue-1", categoryId: "continue", text: "What makes you say that?"}),
  Object.freeze({id: "continue-2", categoryId: "continue", text: "How did that change things for you?"}),
  Object.freeze({id: "continue-3", categoryId: "continue", text: "What part of that matters most to you?"}),
  Object.freeze({id: "continue-4", categoryId: "continue", text: "If you could change one thing about it, what would you change?"}),
  Object.freeze({id: "recover-1", categoryId: "recover", text: "Want to switch topics — what’s been on your mind lately?"}),
  Object.freeze({id: "recover-2", categoryId: "recover", text: "Random question: what’s something you’re looking forward to?"}),
  Object.freeze({id: "recover-3", categoryId: "recover", text: "Let’s reset — tell me something about you I wouldn’t guess."}),
  Object.freeze({id: "recover-4", categoryId: "recover", text: "New topic? What’s something you’ve enjoyed recently?"})
])

const CATEGORY_BY_ID = new Map(PROMPT_CATEGORIES.map((category) => [category.id, category]))
const PROMPT_BY_ID = new Map(PROMPT_CATALOG.map((prompt) => [prompt.id, prompt]))

export function approvedPromptCategory(id) {
  return typeof id === "string" ? CATEGORY_BY_ID.get(id) || null : null
}

export function approvedPrompt(id) {
  return typeof id === "string" ? PROMPT_BY_ID.get(id) || null : null
}

export function promptsForCategory(categoryId) {
  if (!approvedPromptCategory(categoryId)) return []
  return PROMPT_CATALOG.filter((prompt) => prompt.categoryId === categoryId)
}

export function initialPromptCardState() {
  return {open: false, categoryId: "start", promptId: "start-1"}
}

function normalizedState(state) {
  const category = approvedPromptCategory(state?.categoryId) || PROMPT_CATEGORIES[0]
  const selected = approvedPrompt(state?.promptId)
  const prompt = selected?.categoryId === category.id ? selected : promptsForCategory(category.id)[0]
  return {open: Boolean(state?.open), categoryId: category.id, promptId: prompt.id}
}

export function transitionPromptCards(state, operation = {}) {
  const current = normalizedState(state)

  if (operation.type === "open") {
    return {status: current.open ? "no_op" : "opened", state: {...current, open: true}}
  }

  if (operation.type === "close") {
    return {status: current.open ? "closed" : "no_op", state: {...current, open: false}}
  }

  if (operation.type === "select_category") {
    const category = approvedPromptCategory(operation.categoryId)
    if (!category) return {status: "invalid", state: current}
    const prompt = promptsForCategory(category.id)[0]
    const next = {...current, categoryId: category.id, promptId: prompt.id}
    const unchanged = next.categoryId === current.categoryId && next.promptId === current.promptId
    return {status: unchanged ? "no_op" : "selected", state: next}
  }

  if (operation.type === "select_prompt") {
    const prompt = approvedPrompt(operation.promptId)
    if (!prompt) return {status: "invalid", state: current}
    const next = {...current, categoryId: prompt.categoryId, promptId: prompt.id}
    return {status: prompt.id === current.promptId ? "no_op" : "selected", state: next}
  }

  if (operation.type === "reset") {
    const next = initialPromptCardState()
    const unchanged = current.open === next.open && current.categoryId === next.categoryId && current.promptId === next.promptId
    return {status: unchanged ? "no_op" : "reset", state: next}
  }

  return {status: "invalid", state: current}
}

export function insertPromptDraft(currentDraft, promptId) {
  const draft = typeof currentDraft === "string" ? currentDraft : ""
  const prompt = approvedPrompt(promptId)
  if (!prompt) return {status: "invalid", draft}
  if (draft.length > 0) return {status: "blocked_non_empty", draft}
  return {status: "inserted", draft: prompt.text}
}
