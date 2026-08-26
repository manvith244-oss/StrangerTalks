export function createPreferenceSaveQueue() {
  const latestVersion = new Map()
  const tails = new Map()

  return {
    isCurrent(key, version) {
      return latestVersion.get(key) === version
    },

    save(key, operation) {
      if (typeof key !== "string" || !key || typeof operation !== "function") {
        throw new TypeError("invalid_preference_save")
      }

      const version = (latestVersion.get(key) || 0) + 1
      latestVersion.set(key, version)
      const previous = tails.get(key) || Promise.resolve()

      const run = previous.then(() => operation())
      const result = run.then(
        value => ({
          status: latestVersion.get(key) === version ? "saved" : "superseded",
          version,
          value
        }),
        error => ({
          status: latestVersion.get(key) === version ? "failed" : "superseded_failed",
          version,
          error
        })
      )

      tails.set(key, result.then(() => undefined))
      return result
    }
  }
}

export async function saveBooleanPreference({
  queue,
  key,
  recordId,
  valueKey,
  desired,
  putRecord,
  getRecord,
  now = () => new Date().toISOString()
}) {
  const result = await queue.save(key, () => putRecord({
    id: recordId,
    type: "settings",
    value: {[valueKey]: desired},
    updated_at: now()
  }))

  if (result.status !== "failed") return result
  if (!queue.isCurrent(key, result.version)) return {...result, status: "superseded_failed"}

  try {
    const record = await getRecord(recordId)
    if (!queue.isCurrent(key, result.version)) return {...result, status: "superseded_failed"}
    return {
      ...result,
      canonical: record?.value?.[valueKey] === true
    }
  } catch (reconcileError) {
    if (!queue.isCurrent(key, result.version)) return {...result, status: "superseded_failed"}
    return {
      ...result,
      canonical: null,
      reconcileError
    }
  }
}
