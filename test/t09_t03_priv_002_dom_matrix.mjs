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
  window.__t09Clones = []
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
      text: (node.textContent || "").trim().replace(/\s+/g, " ").slice(0, 120),
      ariaLabel: node.getAttribute("aria-label"),
      title: node.getAttribute("title"),
      attrType: node.getAttribute("type"),
      resolvedType: node instanceof HTMLButtonElement ? node.type : null,
      hidden: Boolean(node.hidden),
      outerHTML: node.outerHTML
    }
  }

  const relevantNode = node => {
    if (!(node instanceof Element)) return false
    return Boolean(
      node.matches("#message-form, #message-input, #message-form button, #companion-panel, #companion-generate, .compose") ||
      node.closest?.("#message-form") ||
      node.querySelector?.("#message-form") ||
      node.querySelector?.("#companion-generate")
    )
  }

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === "attributes") {
        const bootFlag = record.target === document.documentElement && record.attributeName === "data-instagram-chat-booted"
        if (!bootFlag && !relevantNode(record.target)) continue
        window.__t09Events.push({
          t: Number(performance.now().toFixed(3)),
          kind: "attribute",
          attribute: record.attributeName,
          oldValue: record.oldValue,
          target: compact(record.target)
        })
        continue
      }

      for (const node of record.removedNodes) {
        if (!(node instanceof Element) || !relevantNode(node)) continue
        window.__t09Events.push({
          t: Number(performance.now().toFixed(3)),
          kind: "removed",
          target: compact(record.target),
          node: compact(node)
        })
      }
      for (const node of record.addedNodes) {
        if (!(node instanceof Element) || !relevantNode(node)) continue
        window.__t09Events.push({
          t: Number(performance.now().toFixed(3)),
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
    if (this instanceof Element && relevantNode(this)) {
      window.__t09Clones.push({
        t: Number(performance.now().toFixed(3)),
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

    function visible(el) {
      const style = getComputedStyle(el)
      const rect = el.getBoundingClientRect()
      return !el.hidden && style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse" && Number(style.opacity || "1") !== 0 && rect.width > 0 && rect.height > 0 && el.getClientRects().length > 0
    }

    function chain(el) {
      const result = []
      let node = el
      while (node instanceof Element) {
        const style = getComputedStyle(node)
        result.push({
          uid: window.__t09Uid?.(node) || null,
          tag: node.tagName.toLowerCase(),
          id: node.id || null,
          className: node.className || null,
          hidden: Boolean(node.hidden),
          display: style.display,
          visibility: style.visibility
        })
        node = node.parentElement
      }
      return result
    }

    function details(button) {
      const style = getComputedStyle(button)
      const ancestors = chain(button)
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
        insideCompose: Boolean(button.closest(".compose")),
        insideCompanionPanel: Boolean(button.closest("#companion-panel")),
        ownerFormId: button.form?.id || null,
        hiddenAncestor: ancestors.find(item => item.hidden || item.display === "none" || item.visibility === "hidden") || null,
        ancestorChain: ancestors
      }
    }

    const formButtons = form ? [...form.querySelectorAll("button")].map(details) : []
    const broad = form ? [...form.querySelectorAll("button.primary")].map(details) : []
    const narrow = compose ? [...compose.querySelectorAll("button.primary")].map(details) : []
    const submit = form ? [...form.querySelectorAll("button")].filter(button => button.type === "submit").map(details) : []
    const instagramResources = performance.getEntriesByType("resource").map(entry => entry.name).filter(name => /instagram_chat\.(?:mjs|css)/.test(name))
    const companionResources = performance.getEntriesByType("resource").map(entry => entry.name).filter(name => /companion\.mjs/.test(name))
    const events = Array.isArray(window.__t09Events) ? window.__t09Events : []
    const clones = Array.isArray(window.__t09Clones) ? window.__t09Clones : []

    const ids = [...document.querySelectorAll("[id]")].map(el => el.id)
    const duplicates = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))]
      .filter(id => ["message-form", "message-input", "companion-panel", "companion-generate"].includes(id))
      .map(id => ({id, count: document.querySelectorAll(`#${CSS.escape(id)}`).length}))

    return {
      point: pointName,
      readyState: document.readyState,
      pathname: location.pathname,
      activeConversationCount: document.querySelectorAll('section[data-screen="conversation"].active').length,
      messageFormCount: document.querySelectorAll("#message-form").length,
      composeCount: document.querySelectorAll("#message-form .compose").length,
      messageInputCount: document.querySelectorAll("#message-input").length,
      formButtonCount: formButtons.length,
      broadPrimaryCount: broad.length,
      narrowPrimaryCount: narrow.length,
      submitButtonCount: submit.length,
      broad,
      narrow,
      submit,
      duplicateRelevantIds: duplicates,
      instagram: {
        resourceLoaded: instagramResources.length > 0,
        resourceNames: instagramResources,
        bootFlag: document.documentElement.dataset.instagramChatBooted || null,
        stylesheetPresent: Boolean(document.querySelector('link[data-instagram-chat-ui="true"]')),
        hardeningStylePresent: Boolean(document.querySelector('style[data-instagram-chat-hardening="true"]')),
        chatMode: document.body.classList.contains("st-chat-mode"),
        plusButtonPresent: Boolean(document.querySelector("#message-form .ig-compose-plus")),
        inputPlaceholder: document.querySelector("#message-input")?.getAttribute("placeholder") || null,
        inputEnterKeyHint: document.querySelector("#message-input")?.getAttribute("enterkeyhint") || null,
        sendAriaLabel: compose?.querySelector("button.primary")?.getAttribute("aria-label") || null,
        sendTitle: compose?.querySelector("button.primary")?.getAttribute("title") || null
      },
      companion: {
        resourceLoaded: companionResources.length > 0,
        resourceNames: companionResources,
        panelPresent: Boolean(document.querySelector("#companion-panel")),
        panelHidden: document.querySelector("#companion-panel")?.hidden ?? null,
        generatePresent: Boolean(document.querySelector("#companion-generate")),
        generateInsideMessageForm: Boolean(document.querySelector("#message-form #companion-generate")),
        generateInsideCompose: Boolean(document.querySelector("#message-form .compose #companion-generate"))
      },
      relevantEvents: events.filter(event => {
        const id = event.target?.id || event.node?.id
        const html = `${event.target?.outerHTML || ""}\n${event.node?.outerHTML || ""}`
        return ["message-form", "message-input", "companion-panel", "companion-generate"].includes(id) || /aria-label="Send message"|ig-compose-send|companion-generate|companion-panel/.test(html) || event.attribute === "data-instagram-chat-booted"
      }),
      relevantClones: clones.filter(event => /message-form|message-input|Send|companion/.test(`${event.source?.outerHTML || ""}\n${event.clone?.outerHTML || ""}`))
    }
  }, point)
}

function printSnapshot(snapshot) {
  const prefix = `T09_${LANE}_${snapshot.point}`
  console.log(`${prefix}_COUNTS=${JSON.stringify({readyState:snapshot.readyState,pathname:snapshot.pathname,activeConversationCount:snapshot.activeConversationCount,messageFormCount:snapshot.messageFormCount,composeCount:snapshot.composeCount,messageInputCount:snapshot.messageInputCount,formButtonCount:snapshot.formButtonCount,broadPrimaryCount:snapshot.broadPrimaryCount,narrowPrimaryCount:snapshot.narrowPrimaryCount,submitButtonCount:snapshot.submitButtonCount,duplicateRelevantIds:snapshot.duplicateRelevantIds})}`)
  console.log(`${prefix}_BROAD=${JSON.stringify(snapshot.broad)}`)
  console.log(`${prefix}_NARROW=${JSON.stringify(snapshot.narrow)}`)
  console.log(`${prefix}_SUBMIT=${JSON.stringify(snapshot.submit)}`)
  console.log(`${prefix}_INSTAGRAM=${JSON.stringify(snapshot.instagram)}`)
  console.log(`${prefix}_COMPANION=${JSON.stringify(snapshot.companion)}`)
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
  return {context, page, boot: await capture(page, "CP1_AFTER_INITIAL_BOOT")}
}

async function establishConversation(browser) {
  const a = await boot(browser, `${LANE}-A`)
  const b = await boot(browser, `${LANE}-B`)
  await a.page.getByRole("button", {name: /Advice/}).click()
  await active(a.page, "queue").waitFor({state: "visible", timeout: WAIT})
  await b.page.getByRole("button", {name: /Advice/}).click()

  await Promise.all([
    a.page.waitForFunction(() => location.pathname === "/conversation", null, {timeout: WAIT}),
    b.page.waitForFunction(() => location.pathname === "/conversation", null, {timeout: WAIT})
  ])
  const entered = await capture(a.page, "CP2_AFTER_BOTH_ENTER_CONVERSATION")

  await Promise.all([
    active(a.page, "conversation").waitFor({state: "visible", timeout: WAIT}),
    active(b.page, "conversation").waitFor({state: "visible", timeout: WAIT})
  ])
  const activeSnapshot = await capture(a.page, "CP3_AFTER_CONVERSATION_ACTIVE")
  return {a, b, entered, activeSnapshot}
}

test(`${LANE} exact compact DOM/runtime Send-authority classification`, {timeout: 180_000}, async () => {
  assert.ok(LANE === "CONTROL" || LANE === "CANDIDATE")
  assert.equal(CHECKED_SHA, EXPECTED_SHA)

  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await establishConversation(browser)
    const before = await capture(pair.a.page, "CP4_BEFORE_SEND_ASSERTION")
    await pair.a.page.evaluate(() => Promise.resolve())
    const microtask = await capture(pair.a.page, "CP5_AFTER_MICROTASK")
    await pair.a.page.waitForTimeout(0)
    const turn = await capture(pair.a.page, "CP6_AFTER_EVENT_LOOP_TURN")

    const snapshots = [pair.a.boot, pair.entered, pair.activeSnapshot, before, microtask, turn]
    snapshots.forEach(printSnapshot)

    const eventEvidence = turn.relevantEvents
    const cloneEvidence = turn.relevantClones
    console.log(`T09_${LANE}_RELEVANT_MUTATIONS=${JSON.stringify(eventEvidence)}`)
    console.log(`T09_${LANE}_RELEVANT_CLONES=${JSON.stringify(cloneEvidence)}`)
    console.log(`T09_${LANE}_NODE_STABILITY=${JSON.stringify({narrowUids:snapshots.map(s=>s.narrow[0]?.uid||null),broadUidSets:snapshots.map(s=>s.broad.map(b=>b.uid)),realSendStable:new Set(snapshots.map(s=>s.narrow[0]?.uid).filter(Boolean)).size<=1})}`)

    assert.equal(pair.a.boot.messageFormCount, 1)
    assert.equal(pair.a.boot.messageInputCount, 1)
    assert.equal(pair.activeSnapshot.activeConversationCount, 1)
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
