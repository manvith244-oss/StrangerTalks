import http from 'node:http'

const port = 4173

const html = `<!doctype html>
<meta charset="utf-8">
<title>SEED-SAFETY-03 Browser Harness</title>
<script>
(() => {
  const DB = 'st-safety-03'
  const STORE = 'records'

  function requestAsPromise(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  async function db() {
    const opening = indexedDB.open(DB, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE)
    return requestAsPromise(opening)
  }

  async function put(key, value) {
    const database = await db()
    await new Promise((resolve, reject) => {
      const tx = database.transaction(STORE, 'readwrite')
      tx.objectStore(STORE).put(value, key)
      tx.oncomplete = resolve
      tx.onerror = () => reject(tx.error)
      tx.onabort = () => reject(tx.error)
    })
    database.close()
  }

  async function get(key) {
    const database = await db()
    const tx = database.transaction(STORE, 'readonly')
    const value = await requestAsPromise(tx.objectStore(STORE).get(key))
    database.close()
    return value
  }

  async function reset() {
    await new Promise((resolve) => {
      const req = indexedDB.deleteDatabase(DB)
      req.onsuccess = resolve
      req.onerror = resolve
      req.onblocked = resolve
    })
  }

  async function storeEd25519() {
    const pair = await crypto.subtle.generateKey({name: 'Ed25519'}, false, ['sign', 'verify'])
    await put('ed25519', pair)
    return {
      privateExtractable: pair.privateKey.extractable,
      publicExtractable: pair.publicKey.extractable,
      algorithm: pair.privateKey.algorithm.name
    }
  }

  async function useStoredEd25519(message = 'safety-03-challenge') {
    const pair = await get('ed25519')
    if (!pair) return {found: false}
    const bytes = new TextEncoder().encode(message)
    const signature = await crypto.subtle.sign('Ed25519', pair.privateKey, bytes)
    const verified = await crypto.subtle.verify('Ed25519', pair.publicKey, signature, bytes)
    return {
      found: true,
      verified,
      privateExtractable: pair.privateKey.extractable,
      algorithm: pair.privateKey.algorithm.name
    }
  }

  async function storeAesEvidence(plaintext = 'evidence-vault-payload') {
    const key = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt'])
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const ciphertext = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key, new TextEncoder().encode(plaintext))
    await put('aes', {key, iv, ciphertext})
    return {extractable: key.extractable, algorithm: key.algorithm.name}
  }

  async function decryptStoredAes() {
    const record = await get('aes')
    if (!record) return {found: false}
    const clear = await crypto.subtle.decrypt({name: 'AES-GCM', iv: record.iv}, record.key, record.ciphertext)
    return {
      found: true,
      plaintext: new TextDecoder().decode(clear),
      extractable: record.key.extractable,
      algorithm: record.key.algorithm.name
    }
  }

  async function storageObservation() {
    const estimate = navigator.storage?.estimate ? await navigator.storage.estimate() : null
    const persisted = navigator.storage?.persisted ? await navigator.storage.persisted() : null
    let persistRequest = null
    if (navigator.storage?.persist) {
      try {
        persistRequest = await Promise.race([
          navigator.storage.persist(),
          new Promise((resolve) => setTimeout(() => resolve('timeout'), 1500))
        ])
      } catch (_) {
        persistRequest = 'error'
      }
    }
    return {estimate, persisted, persistRequest}
  }

  window.seedOps = {
    reset,
    storeEd25519,
    useStoredEd25519,
    storeAesEvidence,
    decryptStoredAes,
    storageObservation,
    async hasRecord(key) { return Boolean(await get(key)) },
    async identity() {
      return {
        userAgent: navigator.userAgent,
        platform: navigator.platform,
        webdriver: navigator.webdriver,
        secureContext: window.isSecureContext
      }
    }
  }
})()
</script>`

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'content-type': 'text/plain'})
    res.end('ok')
    return
  }
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store'
  })
  res.end(html)
})

server.listen(port, '127.0.0.1', () => {
  console.log(`SEED-SAFETY-03 test server listening on ${port}`)
})
