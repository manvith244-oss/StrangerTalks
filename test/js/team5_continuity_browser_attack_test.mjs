import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = "http://localhost:4000"
const WAIT = 15_000
const TEST_TIMEOUT = 180_000

async function boot(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}, acceptDownloads: true})
  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
  await page.waitForFunction(() => document.querySelectorAll("#doors .door").length > 0, null, {timeout: WAIT})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page}
}

async function matchPair(browser, door = "Advice") {
  const a = await boot(browser)
  const b = await boot(browser)
  await a.page.locator(`button.door:has-text("${door}")`).click()
  await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT})
  await b.page.locator(`button.door:has-text("${door}")`).click()
  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})
  ])
  return {a, b}
}

async function endConversation(page) {
  const actions = page.locator("details.overflow")
  if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible", timeout: WAIT})
  await page.locator("#end-confirm").click()
}

async function records(page) {
  return page.evaluate(async () => (await import("/assets/local_data.mjs")).listRecords())
}

async function syncRecords(page) {
  return page.evaluate(async () => {
    const local = await import("/assets/local_data.mjs")
    const sync = await import("/assets/encrypted_sync.mjs")
    return sync.syncableRecords(await local.listRecords())
  })
}

async function replaceWithMergedSync(page, remote) {
  return page.evaluate(async (remoteRecords) => {
    const localData = await import("/assets/local_data.mjs")
    const sync = await import("/assets/encrypted_sync.mjs")
    const current = await localData.listRecords()
    const selected = sync.syncableRecords(current)
    const selectedIds = new Set(selected.map(({id}) => id))
    const merged = await sync.mergeSyncRecords(selected, remoteRecords)
    await localData.replaceRecords([...current.filter(({id}) => !selectedIds.has(id)), ...merged])
    return sync.syncableRecords(await localData.listRecords())
  }, remote)
}

async function makeHostileNewerAndAddUnrelated(page, conversationId) {
  await page.evaluate(async ({conversationId}) => {
    const local = await import("/assets/local_data.mjs")
    const future = new Date(Date.now() + 10 * 60 * 1000).toISOString()
    for (const record of await local.listRecords()) {
      if (record.id === `conversation:${conversationId}` || (record.type === "local_message" && record.value?.conversation_id === conversationId)) {
        await local.putRecord({...record, updated_at: future})
      }
    }
    await local.putRecord({id: "memory:browser-unrelated", type: "memory", value: {text: "legitimate unrelated update"}, updated_at: new Date().toISOString()})
  }, {conversationId})
}

async function importBackupViaUi(page, envelope, passphrase) {
  page.once("dialog", async (dialog) => {
    assert.equal(dialog.type(), "prompt")
    await dialog.accept(passphrase)
  })
  await page.locator("#import-data").setInputFiles({
    name: "strangertalks-browser-proof.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(envelope))
  })
}

function sortedSync(recordsToSort) {
  return [...recordsToSort].sort((left, right) => left.id.localeCompare(right.id))
}

test("real browser Keep -> encrypted restore -> Delete tombstone -> hostile stale device -> convergence", {timeout: TEST_TIMEOUT}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b
  let restored
  let wrongPassword

  try {
    ;({a, b} = await matchPair(browser))

    await a.page.locator("#message-input").fill("continuity-browser-message")
    await a.page.getByRole("button", {name: "Send message", exact: true}).click()
    await b.page.locator("#messages li", {hasText: "continuity-browser-message"}).waitFor({state: "visible", timeout: WAIT})

    await endConversation(a.page)
    await Promise.all([
      a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT}),
      b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT})
    ])

    await Promise.all([a.page.locator("#keep-conversation").click(), b.page.locator("#keep-conversation").click()])
    await Promise.all([
      a.page.locator('section[data-screen="chats"].active').waitFor({state: "visible", timeout: WAIT}),
      b.page.locator('section[data-screen="chats"].active').waitFor({state: "visible", timeout: WAIT})
    ])

    const keptA = await records(a.page)
    const keptConversation = keptA.find((record) => record.type === "local_conversation" && record.value?.status === "kept")
    assert.ok(keptConversation, "explicit Keep stores a retained Conversation in browser IndexedDB")
    const conversationId = keptConversation.value.conversation_id
    assert.ok(keptA.some((record) => record.type === "local_message" && record.value?.conversation_id === conversationId && record.value?.content === "continuity-browser-message"), "kept browser state contains the intended retained message")

    const backupEnvelope = await a.page.evaluate(async () => {
      const local = await import("/assets/local_data.mjs")
      return local.encryptBackup(await local.listRecords(), "correct-browser-passphrase")
    })
    assert.equal(JSON.stringify(backupEnvelope).includes("continuity-browser-message"), false, "encrypted backup contains no plaintext retained message")

    restored = await boot(browser)
    await importBackupViaUi(restored.page, backupEnvelope, "correct-browser-passphrase")
    await restored.page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Backup merged"), null, {timeout: WAIT})
    const restoredRecords = await records(restored.page)
    assert.ok(restoredRecords.some((record) => record.id === `conversation:${conversationId}` && record.value?.status === "kept"), "isolated browser restores intended retained Conversation")
    assert.ok(restoredRecords.some((record) => record.type === "local_message" && record.value?.conversation_id === conversationId && record.value?.content === "continuity-browser-message"), "isolated browser restores intended retained message")

    wrongPassword = await boot(browser)
    await wrongPassword.page.evaluate(async () => {
      const local = await import("/assets/local_data.mjs")
      await local.putRecord({id: "memory:preexisting-safe", type: "memory", value: {text: "must survive failed restore"}, updated_at: new Date().toISOString()})
    })
    await importBackupViaUi(wrongPassword.page, backupEnvelope, "wrong-browser-passphrase")
    await wrongPassword.page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Backup could not be opened"), null, {timeout: WAIT})
    const afterWrongPassword = await records(wrongPassword.page)
    assert.ok(afterWrongPassword.some((record) => record.id === "memory:preexisting-safe"), "wrong password preserves pre-existing valid browser data")
    assert.equal(afterWrongPassword.some((record) => record.id === `conversation:${conversationId}`), false, "wrong password imports no retained Conversation")

    await makeHostileNewerAndAddUnrelated(b.page, conversationId)

    await a.page.getByRole("button", {name: /Open local copy/}).click()
    await a.page.locator('section[data-screen="history"].active').waitFor({state: "visible", timeout: WAIT})
    a.page.once("dialog", (dialog) => dialog.accept())
    await a.page.locator("#history-delete").click()
    await a.page.locator('section[data-screen="chats"].active').waitFor({state: "visible", timeout: WAIT})

    const afterDeleteA = await records(a.page)
    const conversationTombstone = afterDeleteA.find((record) => record.id === `conversation:${conversationId}`)
    assert.equal(conversationTombstone?.type, "sync_tombstone", "real Delete handler creates a Conversation tombstone in browser IndexedDB")
    assert.ok(afterDeleteA.some((record) => record.type === "sync_tombstone" && record.value?.previous_category === "kept_messages"), "real Delete handler tombstones retained messages")

    const hostileB = await syncRecords(b.page)
    assert.ok(hostileB.some((record) => record.id === `conversation:${conversationId}` && record.type === "local_conversation"), "stale browser still carries hostile newer live Conversation")
    assert.ok(hostileB.some((record) => record.id === "memory:browser-unrelated"), "stale browser also carries unrelated legitimate update")

    const canonicalA = await replaceWithMergedSync(a.page, hostileB)
    assert.equal(canonicalA.find((record) => record.id === `conversation:${conversationId}`)?.type, "sync_tombstone", "tombstone beats hostile newer live Conversation during real browser merge")
    assert.ok(canonicalA.some((record) => record.id === "memory:browser-unrelated" && record.type === "memory"), "unrelated legitimate stale-device update survives merge")

    const canonicalB = await replaceWithMergedSync(b.page, canonicalA)
    assert.deepEqual(sortedSync(canonicalB), sortedSync(canonicalA), "both isolated browser stores converge on identical retained sync state")
    assert.equal(canonicalB.find((record) => record.id === `conversation:${conversationId}`)?.type, "sync_tombstone", "stale browser converges to deletion instead of resurrecting")
  } finally {
    await Promise.all([a, b, restored, wrongPassword].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

async function createBondAndLeaveEnded(a, b) {
  await endConversation(a.page)
  await Promise.all([
    a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT}),
    b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT})
  ])

  await a.page.locator("#consent").click()
  await a.page.locator("#consent-status").filter({hasText: /Waiting for mutual consent|Bond created/}).waitFor({state: "visible", timeout: WAIT})
  await b.page.locator("#consent").click()
  await b.page.locator("#consent-status").filter({hasText: /Bond created/}).waitFor({state: "visible", timeout: WAIT})

  if (!(await records(a.page)).some((record) => record.type === "relationship")) {
    await a.page.locator("#consent").click()
    await a.page.locator("#consent-status").filter({hasText: /Bond created/}).waitFor({state: "visible", timeout: WAIT})
  }

  const relationshipA = (await records(a.page)).find((record) => record.type === "relationship")
  const relationshipB = (await records(b.page)).find((record) => record.type === "relationship")
  assert.ok(relationshipA, "first browser retains Bond")
  assert.ok(relationshipB, "second browser retains Bond")
  assert.equal(relationshipA.value.relationship_id, relationshipB.value.relationship_id, "both browsers retain the same Bond")

  await Promise.all([a.page.locator("#fade-conversation").click(), b.page.locator("#fade-conversation").click()])
  await Promise.all([
    a.page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT}),
    b.page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
  ])
  return relationshipA.value.relationship_id
}

async function openBonds(page) {
  await page.locator('#bottom-nav button[data-go="relationships"]').click()
  await page.locator('section[data-screen="relationships"].active').waitFor({state: "visible", timeout: WAIT})
}

async function chooseReconnectDoor(page, door = "Advice") {
  const container = page.locator(".bond-reconnect")
  const privateButton = container.getByRole("button", {name: "Reconnect privately"})
  if (await privateButton.count()) await privateButton.click()
  await container.getByRole("button", {name: door, exact: true}).click()
}

test("real browser Bond -> reconnect -> Block -> stale Bond reconnect is safety-denied", {timeout: TEST_TIMEOUT}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    ;({a, b} = await matchPair(browser, "Advice"))
    const relationshipId = await createBondAndLeaveEnded(a, b)

    await Promise.all([openBonds(a.page), openBonds(b.page)])
    await chooseReconnectDoor(a.page, "Advice")
    await chooseReconnectDoor(b.page, "Advice")
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})
    ])

    const actions = a.page.locator("details.overflow")
    if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
    a.page.once("dialog", (dialog) => dialog.accept())
    await a.page.locator("#block").click()
    await a.page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Conversation ended. Choose what this device should retain."), null, {timeout: WAIT})

    assert.ok((await records(a.page)).some((record) => record.type === "relationship" && record.value?.relationship_id === relationshipId), "private retained Bond may remain locally after Block")

    await openBonds(a.page)
    const reconnect = a.page.locator(`.bond-reconnect[data-relationship-id="${relationshipId}"]`)
    await reconnect.waitFor({state: "visible", timeout: WAIT})

    const privateButton = reconnect.getByRole("button", {name: "Reconnect privately"})
    if (await privateButton.count()) {
      await privateButton.click()
      const advice = reconnect.getByRole("button", {name: "Advice", exact: true})
      if (await advice.count()) await advice.click()
    }

    await reconnect.getByText("Private reconnection is unavailable right now.").waitFor({state: "visible", timeout: WAIT})
    assert.equal(await a.page.locator('section[data-screen="conversation"].active').count(), 0, "stale retained Bond cannot create a forbidden Conversation after durable Block")
  } finally {
    await Promise.all([a, b].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})
