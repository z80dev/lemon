import {readFile} from "node:fs/promises"
import {chromium} from "playwright-core"

const baseUrl = process.env.HOSTED_WEREWOLF_SMOKE_URL
const chromePath = process.env.CHROME_BIN || "/usr/bin/google-chrome-stable"

if (!baseUrl) throw new Error("HOSTED_WEREWOLF_SMOKE_URL is required")

const browser = await chromium.launch({
  executablePath: chromePath,
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage"]
})

const failures = []
const resources = []

function check(condition, message) {
  if (!condition) failures.push(message)
}

async function openSession(label, viewport) {
  const context = await browser.newContext({viewport, reducedMotion: "reduce", colorScheme: "dark"})
  const page = await context.newPage()
  const errors = []

  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error" && !message.text().startsWith("Failed to load resource:")) {
      errors.push(message.text())
    }
  })
  page.on("response", response => {
    if (response.status() >= 500) errors.push(`${response.status()} ${response.url()}`)
  })
  page.on("dialog", dialog => dialog.accept())

  resources.push({label, context, page, errors})
  return page
}

async function waitForLive(page) {
  await page.waitForFunction(() => window.liveSocket?.isConnected(), null, {timeout: 15_000})
}

async function checkViewport(page, label) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  check(overflow <= 1, `${label} overflows horizontally by ${overflow}px`)
}

async function activePlayerIndex(players) {
  for (let index = 0; index < players.length; index += 1) {
    if (await players[index].locator('form[id^="hosted-action-"]').count()) return index
  }

  return -1
}

async function submitFirstAction(page, message) {
  const form = page.locator('form[id^="hosted-action-"]').first()
  await form.waitFor({state: "visible", timeout: 10_000})
  const action = (await form.getAttribute("id")).replace("hosted-action-", "")
  const version = await form.locator('input[name="expected_version"]').inputValue()

  for (const textarea of await form.locator("textarea[required]").all()) {
    await textarea.fill(message)
  }

  await form.getByRole("button", {name: "Commit action"}).click()

  await page.waitForFunction(
    previous => {
      const input = document.querySelector('form[id^="hosted-action-"] input[name="expected_version"]')
      return !input || input.value !== previous
    },
    version,
    {timeout: 10_000}
  )

  return action
}

async function waitForTurnAdvance(players, previousIndex, previousVersion) {
  const deadline = Date.now() + 22_000

  while (Date.now() < deadline) {
    const nextIndex = await activePlayerIndex(players)

    if (nextIndex >= 0) {
      const input = players[nextIndex].locator(
        'form[id^="hosted-action-"] input[name="expected_version"]'
      ).first()
      const nextVersion = await input.inputValue().catch(() => null)
      if (nextIndex !== previousIndex || nextVersion !== previousVersion) return
    }

    await new Promise(resolve => setTimeout(resolve, 250))
  }

  throw new Error("Timed turn did not advance within 22 seconds")
}

try {
  const host = await openSession("desktop host", {width: 1440, height: 900})
  await host.goto(`${baseUrl}/play`, {waitUntil: "domcontentloaded"})
  await waitForLive(host)
  await checkViewport(host, "desktop host landing")
  check(await host.getByText("Host a night of").isVisible(), "host landing hero is missing")

  await host.keyboard.press("Tab")
  check(
    await host.locator(":focus").evaluate(element => element !== document.body),
    "host landing has no keyboard focus target"
  )

  await host.selectOption('select[name="room[player_count]"]', "5")
  await host.selectOption('select[name="room[ai_seats]"]', "0")
  await host.selectOption('select[name="room[turn_timeout_seconds]"]', "15")
  await host.selectOption('select[name="room[visibility]"]', "public_safe")
  await host.selectOption('select[name="room[rules_preset]"]', "classic")
  await Promise.all([
    host.waitForURL(/\/rooms\/[a-f0-9]+\/host$/, {timeout: 10_000}),
    host.getByRole("button", {name: "Create the village"}).click()
  ])
  await waitForLive(host)

  const roomCode = (await host.locator("#hosted-room-code").textContent()).trim()
  const roomId = new URL(host.url()).pathname.split("/")[2]
  check(/^[A-Z2-9]{10}$/.test(roomCode), "hosted room code is malformed")

  const players = []
  for (let index = 0; index < 5; index += 1) {
    const viewport = index === 0 ? {width: 375, height: 812} : {width: 768, height: 1024}
    const page = await openSession(`player ${index + 1}`, viewport)
    await page.goto(`${baseUrl}/join/${roomCode}`, {waitUntil: "domcontentloaded"})
    await waitForLive(page)

    const openSeat = page.locator("article").filter({
      has: page.getByRole("button", {name: /^Claim /})
    }).first()
    await openSeat.locator('input[name="player[display_name]"]').fill(`Player ${index + 1}`)
    await Promise.all([
      page.waitForURL(new RegExp(`/rooms/${roomId}/play$`), {timeout: 10_000}),
      openSeat.getByRole("button", {name: /^Claim /}).click()
    ])
    await waitForLive(page)
    check((await page.locator("#hosted-player-role").textContent()).trim() === "sealed", `player ${index + 1} saw a lobby role`)
    players.push(page)
  }

  await checkViewport(players[0], "375x812 player")

  const watch = await openSession("tablet public watch", {width: 768, height: 1024})
  await watch.goto(`${baseUrl}/rooms/${roomId}/watch`, {waitUntil: "domcontentloaded"})
  await waitForLive(watch)
  await checkViewport(watch, "768x1024 public watch")
  check(await watch.locator('[aria-live="polite"]').count() > 0, "public watch has no live announcer")

  await host.locator("#hosted-start-match").waitFor({state: "visible"})
  check(await host.locator("#hosted-start-match").isEnabled(), "start button stayed disabled after five joins")
  await host.locator("#hosted-start-match").click()
  await host.locator("#hosted-host-status").filter({hasText: "running"}).waitFor({timeout: 10_000})

  const roles = []
  for (const page of players) {
    await page.waitForFunction(() => document.querySelector("#hosted-player-role")?.textContent.trim() !== "sealed")
    roles.push((await page.locator("#hosted-player-role").textContent()).trim().toLowerCase())
  }
  check(roles.filter(role => role === "werewolf").length === 1, "five-player role assignment is unexpected")

  const secret = `PACK_SECRET_${Date.now()}`
  const firstActor = await activePlayerIndex(players)
  check(firstActor >= 0, "no player received the opening turn")
  const openingAction = await submitFirstAction(players[firstActor], secret)
  check(openingAction === "wolf_chat", `opening action was ${openingAction}, not wolf_chat`)
  await players[firstActor].getByText(secret, {exact: true}).first().waitFor({timeout: 10_000})

  for (let index = 0; index < players.length; index += 1) {
    if (index !== firstActor) {
      check(!(await players[index].getByText(secret, {exact: true}).count()), `pack secret leaked to player ${index + 1}`)
    }
  }
  check(!(await watch.getByText(secret, {exact: true}).count()), "pack secret leaked to public watch")

  const timedPlayer = await activePlayerIndex(players)
  check(timedPlayer >= 0, "no player received the timed turn")
  const timedVersion = await players[timedPlayer]
    .locator('form[id^="hosted-action-"] input[name="expected_version"]')
    .first()
    .inputValue()
  await waitForTurnAdvance(players, timedPlayer, timedVersion)

  await host.getByRole("button", {name: "Pause"}).click()
  await host.locator("#hosted-host-status").filter({hasText: "paused"}).waitFor({timeout: 10_000})
  await players[0].locator("#hosted-player-status").filter({hasText: "paused"}).waitFor({timeout: 10_000})

  const reconnectedRole = roles[0]
  await players[0].reload({waitUntil: "domcontentloaded"})
  await waitForLive(players[0])
  check(
    (await players[0].locator("#hosted-player-role").textContent()).trim().toLowerCase() === reconnectedRole,
    "player role changed after reconnect"
  )

  await host.getByRole("button", {name: "Resume"}).click()
  await host.locator("#hosted-host-status").filter({hasText: "running"}).waitFor({timeout: 10_000})

  let completed = false
  for (let turn = 0; turn < 300; turn += 1) {
    const status = (await host.locator("#hosted-host-status").textContent()).trim()
    if (status === "completed") {
      completed = true
      break
    }
    if (status === "stopped") throw new Error("Hosted match stopped before completion")

    const actor = await activePlayerIndex(players)
    if (actor < 0) {
      await new Promise(resolve => setTimeout(resolve, 100))
      continue
    }

    await submitFirstAction(players[actor], `E2E turn ${turn + 1}`)
  }

  check(completed, "hosted match did not complete within 300 actions")
  await watch.getByText("Final roles revealed").waitFor({timeout: 10_000})
  check((await watch.locator("body").innerText()).toLowerCase().includes(" wins"), "public watch did not announce the winner")

  const downloadPromise = host.waitForEvent("download")
  await host.getByRole("link", {name: "Export replay"}).click()
  const download = await downloadPromise
  const replay = JSON.parse(await readFile(await download.path(), "utf8"))
  check(replay.schema === "lemon.hosted_werewolf.replay.v1", "downloaded replay schema is wrong")
  check(typeof replay.final_state_hash === "string", "downloaded replay has no state hash")
  check(!JSON.stringify(replay).includes("token_hash"), "downloaded replay contains token hashes")

  await host.getByRole("button", {name: "Prepare rematch"}).click()
  await host.locator("#hosted-host-status").filter({hasText: "lobby"}).waitFor({timeout: 10_000})

  for (const page of players) {
    await page.locator("#hosted-player-role").filter({hasText: "sealed"}).waitFor({timeout: 10_000})
  }

  await checkViewport(host, "1440x900 host console")
} finally {
  for (const resource of resources) {
    failures.push(...resource.errors.map(error => `${resource.label}: ${error}`))
    await resource.context.close()
  }
  await browser.close()
}

if (failures.length) throw new Error(failures.join("\n"))

console.log("Hosted Werewolf multiplayer smoke passed: 5 sessions, timeout, reconnect, completion, export, rematch")
