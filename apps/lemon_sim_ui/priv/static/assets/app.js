import {Socket} from "https://esm.sh/phoenix@1.7.14"
import {LiveSocket} from "https://esm.sh/phoenix_live_view@1.1.24"

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
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
