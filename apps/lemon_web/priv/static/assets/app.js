import {Socket} from "/assets/vendor/phoenix.mjs"
import {LiveSocket} from "/assets/vendor/phoenix_live_view.esm.js"

const TAB_STORAGE_KEY = "lemon_web_tab_id"

function normalizeAgentId(value) {
  const cleaned = (value || "").trim().replace(/[^a-zA-Z0-9._-]/g, "_")
  return cleaned === "" ? "default" : cleaned
}

function randomHex(bytes = 8) {
  const buffer = new Uint8Array(bytes)
  window.crypto.getRandomValues(buffer)
  return Array.from(buffer, (n) => n.toString(16).padStart(2, "0")).join("")
}

function ensureRootSessionKeyParam() {
  const url = new URL(window.location.href)
  let shouldRewrite = false

  if (url.pathname === "/" && !url.searchParams.get("session_key")) {
    const agentId = normalizeAgentId(url.searchParams.get("agent_id"))

    let tabId = window.sessionStorage.getItem(TAB_STORAGE_KEY)

    if (!tabId) {
      tabId = randomHex()
      window.sessionStorage.setItem(TAB_STORAGE_KEY, tabId)
    }

    url.searchParams.set("session_key", `agent:${agentId}:web:browser:unknown:tab-${tabId}`)
    shouldRewrite = true
  }

  if (url.searchParams.has("token")) {
    url.searchParams.delete("token")
    shouldRewrite = true
  }

  if (shouldRewrite) {
    const query = url.searchParams.toString()
    const nextUrl = query === "" ? url.pathname : `${url.pathname}?${query}`
    window.history.replaceState({}, "", `${nextUrl}${url.hash}`)
  }
}

ensureRootSessionKeyParam()

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket
