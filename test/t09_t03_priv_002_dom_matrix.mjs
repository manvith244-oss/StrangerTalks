import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const LANE = process.env.T09_LANE
const EXPECTED_SHA = process.env.EXPECTED_PRODUCT_SHA
const CHECKED_SHA = process.env.CHECKED_PRODUCT_SHA
const WAIT = 20_000
const VP = {width: 390, height: 844}
const active = (page, screen) => page.locator(`section[data-screen="${screen}"].active`)

function installRuntimeInstrumentation() {
  window.__t09Events = []
  window.__t09CloneEvents = []
  window.__t09UidCounter = 0
  const uids = new WeakMap()
  const uid = node => {
    if (!(node instanceof Node)) return null
    if (!uids.has(node)) uids.set(node, `n${++window.__t09UidCounter}`)
    return uids.get(node)
  }

  const compact = node => {
    if (!(node instanceof Element)) return {uid: uid(node), nodeType: node?.nodeType ?? null}
    return {
      uid: uid(node),
      tag: node.tagName.toLowerCase(),
      id: node.id || null,
      className: node.className || null,
      text: (node.textContent || "").trim().replace(/\s+/g, " ").slice(0, 180),
      ariaLabel: node.getAttribute("aria-label"),
      title: node.getAttribute("title"),
      type: node instanceof HTMLButtonElement ? node.type : node.getAttribute("type"),
      hidden: Boolean(node.hidden),
      outerHTML: node.outerHTML
    }
  }

  const relevant = node => {
    if (!(node instanceof Element)) return false
    return Boolean(
      node.matches("#message-form, #message-input, #message-form button, [data-screen=\"conversation\"]") ||
      node.closest?.("#message-form") ||
      node.querySelector?.("#message-form")
    )
  }

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === "attributes") {
        if (!relevant(record.target) && !(record.target === document.documentElement && record.attributeName === "data-instagram-chat-booted")) continue
        window.__t09Events.push({
          t: performance.now(),
          kind: "attribute",
          attribute: record.attributeName,
          oldValue: record.oldValue,
          target: compact(record.target)
        })
        continue
      }

      for (const node of record.removedNodes) {
        if (!(node instanceof Element) || !relevant(node)) continue
        window.__t09Events.push({
          t: performance.now(),
          kind: "removed",
          target: compact(record.target),
          node: compact(node)
        })
      }
      for (const node of record.addedNodes) {
        if (!(node instanceof Element) || !relevant(node)) continue
        window.__t09Events.push({
          t: performance.now(),
          kind: "added",
          target: compact(record.target),
          node: compact(node)
        })
      }
    }
  })

  observer.observe(document, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeOldValue: true,
    attributeFilter: ["aria-label", "title", "class", "type", "hidden", "data-instagram-chat-booted"]
  })

  const originalCloneNode = Node.prototype.cloneNode
  Node.prototype.cloneNode = function(deep) {
    const clone = originalCloneNode.call(this, deep)
    if (this instanceof Element && relevant(this)) {
      window.__t09CloneEvents.push({
        t: performance.now(),
        source: compact(this),
        clone: compact(clone),
        deep: Boolean(deep)
      })
    }
    return clone
  }

  window.__t09Uid = node => uid(node)
}

async function capture(page, point) {
  return await page.evaluate(pointName => {
    const form = document.querySelector("#message-form")
    const compose = document.querySelector("#message-form .compose")
    const input = document.querySelector("#message-input")

    function visible(el) {
      if (!(el instanceof Element)) return false
      const style = getComputedStyle(el)
      const rect = el.getBoundingClientRect()
      return !el.hidden && style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse" && Number(style.opacity || "1") !== 0 && rect.width > 0 && rect.height > 0 && el.getClientRects().length > 0
    }

    function ancestorChain(el) {
      const chain = []
      let node = el
      while (node instanceof Element) {
        chain.push({
          uid: window.__t09Uid?.(node) || null,
          tag: node.tagName.toLowerCase(),
          id: node.id || null,
          className: node.className || null,
          hidden: Boolean(node.hidden),
          display: getComputedStyle(node).display
        })
        node = node.parentElement
      }
      return chain
    }

    function buttonDetails(button) {
      const style = getComputedStyle(button)
      const hiddenAncestor = ancestorChain(button).find(node => node.hidden || node.display === "none") || null
      return {
        uid: window.__t09Uid?.(button) || null,
        outerHTML: button.outerHTML,
        id: button.id || null,
        textContent: button.textContent,
        ariaLabel: button.getAttribute("aria-label"),
        title: button.getAttribute("title"),
        attrType: button.getAttribute("type"),
        resolvedType: button.type,
        className: button.className,
        hidden: Boolean(button.hidden),
        disabled: Boolean(button.disabled),
        visible: visible(button),
        display: style.display,
        visibility: style.visibility,
        opacity: style.opacity,
        insideCompose: Boolean(button.closest(".compose")),
        insideCompanionPanel: Boolean(button.closest("#companion-panel")),
        insideReportForm: Boolean(button.closest("#report-form")),
        insideVoiceSheet: Boolean(button.closest(".voice-sheet")),
        ownerFormId: button.form?.id || null,
        hiddenAncestor,
        ancestorChain: ancestorChain(button)
      }
    }

    const formButtons = form ? [...form.querySelectorAll("button")].map(buttonDetails) : []
    const broadButtons = form ? [...form.querySelectorAll("button.primary")].map(buttonDetails) : []
    const narrowButtons = compose ? [...compose.querySelectorAll("button.primary")].map(buttonDetails) : []
    const submitButtons = form ? [...form.querySelectorAll("button")].filter(button => button.type === "submit").map(buttonDetails) : []

    const relevantIds = ["message-form", "message-input"]
    const relevantIdCounts = Object.fromEntries(relevantIds.map(id => [id, document.querySelectorAll(`#${id}`).length]))
    const idsInsideForm = form ? [...form.querySelectorAll("[id]")].map(el => el.id) : []
    const duplicateIdsInsideForm = [...new Set(idsInsideForm.filter((id, index) => idsInsideForm.indexOf(id) !== index))]
      .map(id => ({id, countInsideForm: form.querySelectorAll(`#${CSS.escape(id)}`).length, globalCount: document.querySelectorAll(`#${CSS.escape(id)}`).length}))

    const instagramResources = performance.getEntriesByType("resource")
      .map(entry => entry.name)
      .filter(name => /instagram_chat\.(?:mjs|css)/.test(name))

    const companionResources = performance.getEntriesByType("resource")
      .map(entry => entry.name)
      .filter(name => /companion\.mjs/.test(name))

    return {
      point: pointName,
      now: performance.now(),
      readyState: document.readyState,
      pathname: location.pathname,
      activeConversationCount: document.querySelectorAll('section[data-screen="conversation"].active').length,
      conversationSectionClass: document.querySelector('section[data-screen="conversation"]')?.className || null,
      messageFormCount: document.querySelectorAll("#message-form").length,
      composeCount: document.querySelectorAll("#message-form .compose").length,
      messageInputCount: document.querySelectorAll("#message-input").length,
      messageFormButtonCount: formButtons.length,
      broadPrimaryCount: broadButtons.length,
      narrowComposePrimaryCount: narrowButtons.length,
      submitButtonCount: submitButtons.length,
      formButtons,
      broadButtons,
      narrowButtons,
      submitButtons,
      relevantIdCounts,
      duplicateIdsInsideForm,
      instagramChat: {
        resourceLoaded: instagramResources.length > 0,
        resources: instagramResources,
        stylesheetPresent: Boolean(document.querySelector('link[data-instagram-chat-ui="true"]')),
        hardeningStylePresent: Boolean(document.querySelector('style[data-instagram-chat-hardening="true"]')),
        bootFlag: document.documentElement.dataset.instagramChatBooted || null,
        chatMode: document.body.classList.contains("st-chat-mode"),
        plusButtonPresent: Boolean(document.querySelector("#message-form .ig-compose-plus")),
        inputPlaceholder: input?.getAttribute("placeholder") || null,
        inputEnterKeyHint: input?.getAttribute("enterkeyhint") || null,
        inputValueObserved: input?.dataset?.igValueObserved || null,
        realComposeSendAriaLabel: compose?.querySelector("button.primary")?.getAttribute("aria-label") || null,
        realComposeSendTitle: compose?.querySelector("button.primary")?.getAttribute("title") || null
      },
      companion: {
        resourceLoaded: companionResources.length > 0,
        resources: companionResources,
        controlPresent: Boolean(document.querySelector("#companion-control")),
        panelPresent: Boolean(document.querySelector("#companion-panel")),
        generatePresent: Boolean(document.querySelector("#companion-generate")),
        generateInsideMessageForm: Boolean(document.querySelector("#message-form #companion-generate")),
        generatePrimary: Boolean(document.querySelector("#message-form #companion-generate.primary"))
      },
      mutationEvents: Array.isArray(window.__t09Events) ? [...window.__t09Events] : [],
      cloneEvents: Array.isArray(window.__t09CloneEvents) ? [...window.__t09CloneEvents] : []
    }
  }, point)
}

async function boot(browser, label) {
  const context = await browser.newContext({viewport: VP})
  await context.addInitScript(installRuntimeInstrumentation)
  const page = await context.newPage()
  const issuanceWait = page.waitForResponse(response => {
    try { return new URL(response.url()).pathname === "/api/participants" } catch { return false }
  })
  const response = await page.goto(BASE, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), `${label}: root loads`)
  assert.ok((await issuanceWait).ok(), `${label}: participant issuance succeeds`)
  await active(page, "doors").waitFor({state: "visible", timeout: WAIT})
  await page.locator("#conversation-language").selectOption("en")
  const bootSnapshot = await capture(page, `${label}_CHECKPOINT_1_AFTER_INITIAL_BOOT`)
  return {context, page, bootSnapshot}
}

async function establishConversation(browser) {
  const a = await boot(browser, `${LANE}_A`)
  const b = await boot(browser, `${LANE}_B`)

  await a.page.getByRole("button", {name: /Advice/}).click()
  await active(a.page, "queue").waitFor({state: "visible", timeout: WAIT})
  await b.page.getByRole("button", {name: /Advice/}).click()

  await Promise.all([
    a.page.waitForFunction(() => location.pathname === "/conversation", null, {timeout: WAIT}),
    b.page.waitForFunction(() => location.pathname === "/conversation", null, {timeout: WAIT})
  ])
  const afterBothEnter = await capture(a.page, `${LANE}_CHECKPOINT_2_AFTER_BOTH_ENTER_CONVERSATION`)

  await Promise.all([
    active(a.page, "conversation").waitFor({state: "visible", timeout: WAIT}),
    active(b.page, "conversation").waitFor({state: "visible", timeout: WAIT})
  ])
  const afterActive = await capture(a.page, `${LANE}_CHECKPOINT_3_AFTER_CONVERSATION_ACTIVE`)
  const bAfterActive = await capture(b.page, `${LANE}_B_CHECKPOINT_3_AFTER_CONVERSATION_ACTIVE`)

  return {a, b, afterBothEnter, afterActive, bAfterActive}
}

function summarizeTimeline(snapshots) {
  const realSendUids = snapshots.map(snapshot => snapshot.narrowButtons[0]?.uid || null)
  const broadCounts = snapshots.map(snapshot => snapshot.broadPrimaryCount)
  const accessibleLabels = snapshots.map(snapshot => snapshot.instagramChat.realComposeSendAriaLabel)
  return {
    points: snapshots.map(snapshot => snapshot.point),
    realSendUids,
    realSendStable: new Set(realSendUids.filter(Boolean)).size <= 1,
    broadCounts,
    accessibleLabels,
    instagramBootFlags: snapshots.map(snapshot => snapshot.instagramChat.bootFlag),
    instagramResourcesSeen: snapshots.map(snapshot => snapshot.instagramChat.resourceLoaded),
    companionGenerateSeen: snapshots.map(snapshot => snapshot.companion.generatePresent)
  }
}

test(`${LANE} exact DOM/runtime Send-authority timeline`, {timeout: 180_000}, async () => {
  assert.ok(LANE === "CONTROL" || LANE === "CANDIDATE", "lane must be exact CONTROL or CANDIDATE")
  assert.equal(CHECKED_SHA, EXPECTED_SHA, "workflow product checkout must equal exact requested lane SHA")

  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await establishConversation(browser)
    const preAssertion = await capture(pair.a.page, `${LANE}_CHECKPOINT_4_IMMEDIATELY_BEFORE_SEND_ASSERTION`)
    await pair.a.page.evaluate(() => Promise.resolve())
    const afterMicrotask = await capture(pair.a.page, `${LANE}_CHECKPOINT_5_AFTER_MICROTASK`)
    await pair.a.page.waitForTimeout(0)
    const afterTurn = await capture(pair.a.page, `${LANE}_CHECKPOINT_6_AFTER_EVENT_LOOP_TURN`)

    const snapshots = [
      pair.a.bootSnapshot,
      pair.afterBothEnter,
      pair.afterActive,
      preAssertion,
      afterMicrotask,
      afterTurn
    ]

    for (const snapshot of snapshots) {
      console.log(`T09_${LANE}_DOM_${snapshot.point}=${JSON.stringify(snapshot)}`)
    }
    console.log(`T09_${LANE}_B_ACTIVE=${JSON.stringify(pair.bAfterActive)}`)
    console.log(`T09_${LANE}_TIMELINE_SUMMARY=${JSON.stringify(summarizeTimeline(snapshots))}`)

    assert.equal(pair.a.bootSnapshot.messageFormCount, 1)
    assert.equal(pair.a.bootSnapshot.messageInputCount, 1)
    assert.equal(pair.afterActive.activeConversationCount, 1)
    assert.equal(pair.bAfterActive.activeConversationCount, 1)
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")
    assert.equal(new URL(pair.b.page.url()).pathname, "/conversation")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
