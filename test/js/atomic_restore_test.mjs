import assert from "node:assert/strict"
import test from "node:test"
import {atomicReplaceRecords} from "../../priv/static/assets/local_data.mjs"

const oldRecord = {id: "memory:old", type: "memory", value: {text: "old"}, updated_at: "2026-08-06T00:00:00Z"}
const replacements = [
  {id: "memory:new-1", type: "memory", value: {text: "one"}, updated_at: "2026-08-06T00:00:00Z"},
  {id: "memory:new-2", type: "memory", value: {text: "two"}, updated_at: "2026-08-06T00:00:00Z"}
]

function transactionalAdapter(initial, failAt = null, error = new Error("write_failed")) {
  const state = {records: structuredClone(initial)}
  return {state, run: async (operations) => {
    const draft = structuredClone(state.records)
    try {
      for (const [index, operation] of operations.entries()) {
        if (index === failAt) throw error
        if (operation.action === "clear") draft.splice(0)
        else draft.push(structuredClone(operation.record))
      }
      state.records = draft
    } catch (caught) { throw caught }
  }}
}

test("atomic restore commits one complete replacement", async () => {
  const adapter = transactionalAdapter([oldRecord])
  await atomicReplaceRecords(replacements, adapter)
  assert.deepEqual(adapter.state.records, replacements)
})

for (const [name, failAt, error] of [
  ["failure on first operation", 0, new Error("first")],
  ["failure midway", 2, new Error("midway")],
  ["quota error", 1, Object.assign(new Error("quota"), {name: "QuotaExceededError"})],
  ["transaction abort", 2, Object.assign(new Error("abort"), {name: "AbortError"})],
  ["refresh interruption", 1, new Error("interrupted")]
]) test(`atomic restore preserves previous state after ${name}`, async () => {
  const adapter = transactionalAdapter([oldRecord], failAt, error)
  await assert.rejects(() => atomicReplaceRecords(replacements, adapter))
  assert.deepEqual(adapter.state.records, [oldRecord])
})
