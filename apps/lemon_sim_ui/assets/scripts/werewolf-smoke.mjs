import {writeFile} from "node:fs/promises"
import {chromium} from "playwright-core"

const target = process.env.WEREWOLF_SMOKE_URL
const readyFile = process.env.WEREWOLF_SMOKE_READY_FILE
const expectedInitial = process.env.WEREWOLF_SMOKE_INITIAL_PHASE
const expectedUpdated = process.env.WEREWOLF_SMOKE_UPDATED_PHASE
const chromePath = process.env.CHROME_BIN || "/usr/bin/google-chrome-stable"

if (!target) throw new Error("WEREWOLF_SMOKE_URL is required")

const browser = await chromium.launch({
  executablePath: chromePath,
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage"]
})

const failures = []

async function openPage(viewport) {
  const page = await browser.newPage({viewport})
  const browserErrors = []
  let websocketCount = 0

  page.on("console", message => {
    if (message.type() === "error" && !message.text().startsWith("Failed to load resource:")) {
      browserErrors.push(message.text())
    }
  })
  page.on("pageerror", error => browserErrors.push(error.message))
  page.on("response", response => {
    if (response.status() >= 400) browserErrors.push(`${response.status()} ${response.url()}`)
  })
  page.on("requestfailed", request => {
    browserErrors.push(`${request.failure()?.errorText || "request failed"} ${request.url()}`)
  })
  page.on("websocket", () => websocketCount += 1)

  await page.emulateMedia({reducedMotion: "reduce"})
  await page.goto(target, {waitUntil: "domcontentloaded"})

  try {
    await page.waitForFunction(() => window.liveSocket?.isConnected(), null, {timeout: 15_000})
  } catch (error) {
    const liveState = await page.evaluate(() => ({
      hasLiveSocket: Boolean(window.liveSocket),
      readyState: document.readyState,
      rootClass: document.querySelector("[data-phx-main]")?.className || ""
    }))
    throw new Error(`${error.message}\n${JSON.stringify(liveState)}\n${browserErrors.join("\n")}`)
  }
  await page.waitForSelector("#werewolf-story")

  if (websocketCount < 1) failures.push(`${viewport.width}px did not establish a WebSocket`)

  const checks = await page.evaluate(() => {
    const state = document.querySelector("#werewolf-state-heading")?.closest("section")
    const story = document.querySelector("#werewolf-story")
    const roster = document.querySelector("#werewolf-roster-heading")?.closest("section")

    return {
      overflow: document.documentElement.scrollWidth - window.innerWidth,
      stateTop: state?.getBoundingClientRect().top,
      storyTop: story?.getBoundingClientRect().top,
      rosterTop: roster?.getBoundingClientRect().top,
      announcer: Boolean(story?.querySelector('[role="status"][aria-live="polite"]')),
      roleImageCount: document.querySelectorAll('img[src*="/werewolf/werewolf.png"], img[src*="/werewolf/seer.png"], img[src*="/werewolf/doctor.png"], img[src*="/werewolf/villager.png"]').length
    }
  })

  if (checks.overflow > 1) failures.push(`${viewport.width}px overflows horizontally by ${checks.overflow}px`)
  if (!checks.announcer) failures.push(`${viewport.width}px is missing the concise live announcer`)
  if (checks.roleImageCount > 0) failures.push(`${viewport.width}px still loads inconsistent role portraits`)

  if (viewport.width < 640 && !(checks.stateTop < checks.storyTop && checks.storyTop < checks.rosterTop)) {
    failures.push(`${viewport.width}px content order is not state, story, roster`)
  }

  await page.keyboard.press("Tab")
  const firstFocus = await page.locator(":focus").textContent()
  if (!firstFocus?.includes("Skip to live story")) {
    failures.push(`${viewport.width}px does not expose the story skip link first`)
  }

  return {page, browserErrors}
}

try {
  const live = await openPage({width: 390, height: 844})

  if (expectedInitial) {
    await live.page.waitForFunction(
      phase => document.querySelector("#werewolf-phase-heading")?.textContent.includes(phase),
      expectedInitial,
      {timeout: 10_000}
    )
  }

  if (readyFile) await writeFile(readyFile, "ready\n")

  if (expectedUpdated) {
    await live.page.waitForFunction(
      phase => document.querySelector("#werewolf-phase-heading")?.textContent.includes(phase),
      expectedUpdated,
      {timeout: 20_000}
    )
  }

  failures.push(...live.browserErrors.map(error => `390px browser error: ${error}`))
  await live.page.close()

  for (const viewport of [{width: 320, height: 568}, {width: 1440, height: 1000}]) {
    const result = await openPage(viewport)
    failures.push(...result.browserErrors.map(error => `${viewport.width}px browser error: ${error}`))
    await result.page.close()
  }
} finally {
  await browser.close()
}

if (failures.length > 0) throw new Error(failures.join("\n"))

console.log("Werewolf LiveView browser smoke passed at 320px, 390px, and 1440px")
