import {Socket} from "https://cdn.jsdelivr.net/npm/phoenix@1.8.1/priv/static/phoenix.esm.js"
import {LiveSocket} from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.18/priv/static/phoenix_live_view.esm.js"

const Hooks = {}

Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  longPollFallbackMs: 2500
})

liveSocket.connect()
window.liveSocket = liveSocket
