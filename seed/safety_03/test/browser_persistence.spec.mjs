import {test, expect, chromium, firefox, webkit} from '@playwright/test'
import {mkdtemp, rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'

const browserTypes = {chromium, firefox, webkit}

async function identity(page, browserVersion, testInfo) {
  const browserIdentity = await page.evaluate(() => window.seedOps.identity())
  await testInfo.attach('browser-identity', {
    body: Buffer.from(JSON.stringify({
      project: testInfo.project.name,
      configuredBrowserName: testInfo.project.use.browserName,
      browserVersion,
      ...browserIdentity
    }, null, 2)),
    contentType: 'application/json'
  })
  return browserIdentity
}

async function newPersistentPage(browserName, userDataDir) {
  const type = browserTypes[browserName]
  if (!type) throw new Error(`unsupported_browser_type:${browserName}`)
  const context = await type.launchPersistentContext(userDataDir, {headless: true})
  const page = context.pages()[0] || await context.newPage()
  await page.goto('http://127.0.0.1:4173')
  return {context, page}
}

test('non-extractable Ed25519 CryptoKey survives IndexedDB page reload and remains usable', async ({page, browser}, testInfo) => {
  await page.goto('/')
  const id = await identity(page, browser.version(), testInfo)
  expect(id.secureContext).toBe(true)
  await page.evaluate(() => window.seedOps.reset())

  const created = await page.evaluate(() => window.seedOps.storeEd25519())
  expect(created.privateExtractable).toBe(false)
  expect(created.algorithm).toBe('Ed25519')

  await page.reload()
  const loaded = await page.evaluate(() => window.seedOps.useStoredEd25519('reload-challenge'))
  expect(loaded.found).toBe(true)
  expect(loaded.verified).toBe(true)
  expect(loaded.privateExtractable).toBe(false)
})

test('non-extractable AES-GCM evidence-vault key survives IndexedDB page reload and decrypts retained ciphertext', async ({page}) => {
  await page.goto('/')
  await page.evaluate(() => window.seedOps.reset())
  const created = await page.evaluate(() => window.seedOps.storeAesEvidence('retained-evidence'))
  expect(created.extractable).toBe(false)

  await page.reload()
  const loaded = await page.evaluate(() => window.seedOps.decryptStoredAes())
  expect(loaded.found).toBe(true)
  expect(loaded.plaintext).toBe('retained-evidence')
  expect(loaded.extractable).toBe(false)
})

test('non-extractable Ed25519 and AES-GCM keys survive a browser-process restart in the same persistent profile', async ({}, testInfo) => {
  const browserName = testInfo.project.use.browserName
  const profile = await mkdtemp(join(tmpdir(), `safety03-${browserName}-`))
  try {
    let opened = await newPersistentPage(browserName, profile)
    await opened.page.evaluate(() => window.seedOps.reset())
    await opened.page.evaluate(() => window.seedOps.storeEd25519())
    await opened.page.evaluate(() => window.seedOps.storeAesEvidence('process-restart-evidence'))
    await opened.context.close()

    opened = await newPersistentPage(browserName, profile)
    const ed = await opened.page.evaluate(() => window.seedOps.useStoredEd25519('process-restart-challenge'))
    const aes = await opened.page.evaluate(() => window.seedOps.decryptStoredAes())
    expect(ed.found).toBe(true)
    expect(ed.verified).toBe(true)
    expect(ed.privateExtractable).toBe(false)
    expect(aes.found).toBe(true)
    expect(aes.plaintext).toBe('process-restart-evidence')
    expect(aes.extractable).toBe(false)
    await opened.context.close()
  } finally {
    await rm(profile, {recursive: true, force: true})
  }
})

test('isolated/private-like browser context destruction removes IndexedDB evidence from the next context', async ({browser}) => {
  let context = await browser.newContext()
  let page = await context.newPage()
  await page.goto('http://127.0.0.1:4173')
  await page.evaluate(() => window.seedOps.storeAesEvidence('ephemeral-context-evidence'))
  expect(await page.evaluate(() => window.seedOps.hasRecord('aes'))).toBe(true)
  await context.close()

  context = await browser.newContext()
  page = await context.newPage()
  await page.goto('http://127.0.0.1:4173')
  expect(await page.evaluate(() => window.seedOps.hasRecord('aes'))).toBe(false)
  await context.close()
})

test('site-data deletion destroys locally retained keys and evidence', async ({page}) => {
  await page.goto('/')
  await page.evaluate(() => window.seedOps.storeEd25519())
  await page.evaluate(() => window.seedOps.storeAesEvidence('delete-me'))
  expect(await page.evaluate(() => window.seedOps.hasRecord('ed25519'))).toBe(true)
  expect(await page.evaluate(() => window.seedOps.hasRecord('aes'))).toBe(true)

  await page.evaluate(() => window.seedOps.reset())
  expect(await page.evaluate(() => window.seedOps.hasRecord('ed25519'))).toBe(false)
  expect(await page.evaluate(() => window.seedOps.hasRecord('aes'))).toBe(false)
})

test('separate browser profiles cannot read each other evidence vaults', async ({}, testInfo) => {
  const browserName = testInfo.project.use.browserName
  const profileA = await mkdtemp(join(tmpdir(), `safety03-a-${browserName}-`))
  const profileB = await mkdtemp(join(tmpdir(), `safety03-b-${browserName}-`))
  try {
    const a = await newPersistentPage(browserName, profileA)
    await a.page.evaluate(() => window.seedOps.storeAesEvidence('profile-a-only'))
    await a.context.close()

    const b = await newPersistentPage(browserName, profileB)
    expect(await b.page.evaluate(() => window.seedOps.hasRecord('aes'))).toBe(false)
    await b.context.close()
  } finally {
    await rm(profileA, {recursive: true, force: true})
    await rm(profileB, {recursive: true, force: true})
  }
})

test('storage persistence API is observed but not mistaken for a durability guarantee', async ({page}, testInfo) => {
  await page.goto('/')
  const observation = await page.evaluate(() => window.seedOps.storageObservation())
  await testInfo.attach('storage-observation', {
    body: Buffer.from(JSON.stringify(observation, null, 2)),
    contentType: 'application/json'
  })
  expect(observation).toHaveProperty('persisted')
  expect(observation).toHaveProperty('persistRequest')
})
