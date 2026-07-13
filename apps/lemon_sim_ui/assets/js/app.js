import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const Hooks = {}

Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, {childList: true, subtree: true})
  },
  updated() {
    this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    if (this.el.dataset.autoscroll === "false") return
    this.el.scrollTop = this.el.scrollHeight
  }
}

Hooks.WerewolfStory = {
  mounted() {
    this.atLiveEdge = true
    this.onNewUpdatesClick = () => {
      const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      this.el.scrollIntoView({behavior: reducedMotion ? "auto" : "smooth", block: "start"})
      this.atLiveEdge = true
      this.hideIndicator()
    }
    this.bindStoryElements()
  },
  updated() {
    const wasAtLiveEdge = this.atLiveEdge
    this.bindStoryElements()
    if (!wasAtLiveEdge) this.showIndicator()
  },
  destroyed() {
    if (this.edgeObserver) this.edgeObserver.disconnect()
    if (this.indicator) this.indicator.removeEventListener("click", this.onNewUpdatesClick)
  },
  bindStoryElements() {
    if (this.edgeObserver) this.edgeObserver.disconnect()
    if (this.indicator) this.indicator.removeEventListener("click", this.onNewUpdatesClick)

    this.indicator = this.el.querySelector("[data-new-updates]")
    this.liveEdge = this.el.querySelector("[data-live-edge]")
    if (this.indicator) this.indicator.addEventListener("click", this.onNewUpdatesClick)

    if (!this.liveEdge) return

    this.edgeObserver = new IntersectionObserver(([entry]) => {
      this.atLiveEdge = entry.isIntersecting
      if (this.atLiveEdge) this.hideIndicator()
    }, {threshold: 0.5})
    this.edgeObserver.observe(this.liveEdge)
  },
  showIndicator() {
    if (this.indicator) this.indicator.hidden = false
  },
  hideIndicator() {
    if (this.indicator) this.indicator.hidden = true
  }
}

Hooks.HostedCountdown = {
  mounted() {
    this.renderRemaining = () => {
      const deadline = Number(this.el.dataset.deadline)
      const remaining = Math.max(0, Math.ceil((deadline - Date.now()) / 1000))
      this.el.textContent = remaining === 1 ? "1 second remaining" : `${remaining} seconds remaining`
    }
    this.renderRemaining()
    this.timer = window.setInterval(this.renderRemaining, 1000)
  },
  updated() {
    this.renderRemaining()
  },
  destroyed() {
    window.clearInterval(this.timer)
  }
}

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  longPollFallbackMs: null
})

liveSocket.connect()
window.liveSocket = liveSocket
