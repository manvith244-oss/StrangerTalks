import {defineConfig} from '@playwright/test'

export default defineConfig({
  testDir: './test',
  testMatch: /browser_persistence\.spec\.mjs/,
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  expect: {timeout: 10_000},
  reporter: [['line']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    trace: 'retain-on-failure'
  },
  webServer: {
    command: 'node src/test_server.mjs',
    url: 'http://127.0.0.1:4173/health',
    reuseExistingServer: false,
    timeout: 30_000
  },
  projects: [
    {name: 'chromium-cft', use: {browserName: 'chromium'}},
    {name: 'firefox', use: {browserName: 'firefox'}},
    {name: 'webkit-linux', use: {browserName: 'webkit'}},
    {
      name: 'webkit-mobile-emulation',
      use: {
        browserName: 'webkit',
        viewport: {width: 390, height: 844},
        isMobile: true,
        hasTouch: true
      }
    }
  ]
})
