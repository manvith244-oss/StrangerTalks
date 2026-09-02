import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT = 15_000
const CORRUPT_PARTICIPANT = "11111111-1111-4111-8111-111111111111"
const IDENTITY_KEY = "strangertalks.identity.v1"

test("BROWSER-03 corrupt persisted identity is rejected before canonical participant boot", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 1100, height: 760}})
  const page = await context.newPage()

  try {
    // Establish the StrangerTalks origin without executing the application entrypoint.
    const asset = await page.goto(`${BASE}/assets/app.js`, {waitUntil: "domcontentloaded"})
    assert.ok(asset?.ok())

    await page.evaluate(async ({identityKey, corruptParticipant}) => {
      await new Promise((resolve, reject) => {
        const opening = indexedDB.open("strangertalks-local-v1", 1)
        opening.onupgradeneeded = () => opening.result.createObjectStore("records", {keyPath: "id"})
        opening.onerror = () => reject(opening.error)
        opening.onsuccess = () => {
          const db = opening.result
          const tx = db.transaction("records", "readwrite")
          tx.objectStore("records").put({
            id: identityKey,
            type: "identity",
            value: {participant_id: corruptParticipant},
            updated_at: new Date().toISOString()
          })
          tx.oncomplete = () => { db.close(); resolve() }
          tx.onerror = () => reject(tx.error)
          tx.onabort = () => reject(tx.error || new Error("seed_aborted"))
        }
      })
    }, {identityKey: IDENTITY_KEY, corruptParticipant: CORRUPT_PARTICIPANT})

    const response = await page.goto(BASE, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok())
    await page.waitForFunction(() => {
      const state = window.StrangerTalksF11?.getReadiness?.()
      return state?.status === "READY" && state?.canonical_state === "AVAILABLE"
    }, null, {timeout: WAIT})

    const result = await page.evaluate(async (identityKey) => {
      const state = window.StrangerTalksF11.getReadiness()
      const record = await (await import("/assets/local_data.mjs")).getRecord(identityKey)
      return {participantId: state.snapshot.participant_id, record}
    }, IDENTITY_KEY)

    assert.notEqual(result.participantId, CORRUPT_PARTICIPANT)
    assert.equal(result.record?.type, "identity")
    assert.equal(typeof result.record?.value?.token, "string")
    assert.ok(result.record.value.token.length > 0)
    assert.equal(result.record.value.participant_id, result.participantId)
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
