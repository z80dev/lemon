<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'
import LemonFace from './LemonFace.vue'

const root = ref(null)
const armed = ref(false)
const playing = ref(false)
let observer
onMounted(() => {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
  const box = root.value.getBoundingClientRect()
  if (box.top < innerHeight && box.bottom > 0 && box.left < innerWidth && box.right > 0) return
  if (!('IntersectionObserver' in window)) return
  armed.value = true
  observer = new IntersectionObserver(([entry]) => {
    if (entry.intersectionRatio >= 0.4) {
      playing.value = true
      observer.disconnect()
    }
  }, { threshold: 0.4 })
  observer.observe(root.value)
})
onBeforeUnmount(() => observer?.disconnect())
</script>

<template>
  <div ref="root" class="ios-app-mock" :class="{ armed, playing }" aria-hidden="true">
    <div class="ios-phone">
      <div class="ios-screen">
        <div class="ios-native">
          <div class="ios-status"><b>9:41</b><span class="ios-island"/><div class="ios-status-icons"><svg viewBox="0 0 22 18"><path d="M2 15v-3m5 3V9m5 6V6m5 9V3" stroke-width="3"/></svg><svg viewBox="0 0 22 18"><path d="M2 6a14 14 0 0 1 18 0M5 9a9 9 0 0 1 12 0m-9 3a4 4 0 0 1 6 0" stroke-width="2.6"/><circle cx="11" cy="15" r="1" fill="currentColor" stroke="none"/></svg><svg class="ios-battery" viewBox="0 0 28 16"><rect x="1" y="2" width="23" height="12" rx="3" opacity=".45"/><path d="M26 6v4" opacity=".45"/><rect x="3" y="4" width="19" height="8" rx="1" fill="currentColor" stroke="none"/></svg></div></div>
          <div class="ios-navigation"><span class="ios-back"><svg viewBox="0 0 12 20"><path d="m10 2-8 8 8 8"/></svg>Chats</span><span class="ios-title"><LemonFace :size="22"/><b>Lemon</b></span><span class="ios-menu">•••</span></div>
          <div class="ios-transcript">
            <div class="ios-date">Today, 9:41 AM</div>
            <div class="ios-message ios-mine step step-one">Why is <code>upload_test</code> flaky?</div>
            <div class="ios-message ios-assistant step step-two">Two tests share <code>/tmp/uploads</code>. I gave each its own temp dir.</div>
            <div class="ios-gate step step-three"><strong class="ios-command">mix test test/upload_test.exs</strong><span class="ios-machine">Terminal on This Mac</span><span class="ios-details">Details <span>›</span></span><div class="ios-decision"><div class="ios-pending"><span class="ios-allow">Allow once</span><span>Allow Terminal for this chat</span><span>Deny</span></div><span class="ios-resolved">Allowed once by you · 9:41 AM</span></div></div>
            <div class="ios-tool step step-four"><svg viewBox="0 0 20 18"><rect x="1" y="2" width="18" height="14" rx="2"/><path d="m4 6 4 3-4 3m6 0h5"/></svg>Run upload tests <svg class="ios-check" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8"/><path d="m5 10 3 3 7-7"/></svg><span>0.8s</span></div>
            <div class="ios-message ios-assistant step step-four">2 tests, 0 failures. All green.</div>
          </div>
          <div class="ios-composer"><span class="ios-attach">+</span><span class="ios-placeholder">Message Lemon</span><svg class="ios-mic" viewBox="0 0 18 22"><rect x="6" y="1" width="6" height="12" rx="3"/><path d="M3 9v2a6 6 0 0 0 12 0V9M9 17v4m-3 0h6"/></svg><span class="ios-voice"><svg viewBox="0 0 20 20"><path d="M3 8v4m4-7v10m3-13v16m3-13v10m4-7v4"/></svg></span></div>
          <div class="ios-home"><span/></div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.ios-app-mock { --ios-canvas: #f8f8f4; --ios-bubble: #ebece3; --ios-raised: #fff; --ios-fill: rgb(43 49 42 / 6%); --ios-separator: rgb(43 49 42 / 9%); --ios-ink: #2b312a; --ios-muted: #5a6257; --ios-faint: #676f64; --ios-accent: #3c6248; --ios-on-accent: #fff; --ios-success: #3b7347; width: 100%; height: 280px; display: flex; justify-content: center; align-items: center; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif; color: var(--ios-ink); text-align: left; line-height: 1.4; }
.ios-app-mock * { box-sizing: border-box; }
.ios-app-mock svg { display: block; flex: none; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
.ios-phone { width: 154px; height: 280px; padding: 4px; background: #171817; border: 1px solid #63645f; border-radius: 25px; box-shadow: inset 0 0 0 1px #000, 0 8px 16px #0002; position: relative; }
.ios-phone::before, .ios-phone::after { content: ''; position: absolute; width: 2px; background: #51524e; border-radius: 1px; }
.ios-phone::before { height: 24px; left: -2px; top: 53px; }
.ios-phone::after { height: 19px; right: -2px; top: 64px; }
.ios-screen { width: 144px; height: 270px; overflow: hidden; border-radius: 20px; background: var(--ios-canvas); }
/* A 360pt native canvas, miniaturized as one piece so all glyphs and radii share the same scale. */
.ios-native { width: 360px; height: 675px; transform: scale(.4); transform-origin: top left; display: flex; flex-direction: column; background: var(--ios-canvas); font-size: 16px; }
.ios-status { height: 53px; flex: none; position: relative; display: flex; align-items: center; justify-content: space-between; padding: 0 22px; color: var(--ios-ink); }
.ios-status > b { font-size: 14px; font-weight: 600; padding-left: 6px; }
.ios-island { position: absolute; width: 104px; height: 28px; border-radius: 25px; background: #080908; top: 9px; left: 128px; }
.ios-island::after { content: ''; position: absolute; width: 7px; height: 7px; background: #151c26; border: 1px solid #202632; border-radius: 50%; right: 10px; top: 10px; }
.ios-status-icons { display: flex; align-items: center; gap: 4px; }
.ios-status-icons svg { width: 18px; height: 16px; }
.ios-status-icons .ios-battery { width: 25px; }
.ios-navigation { display: flex; align-items: center; justify-content: center; height: 49px; flex: none; position: relative; }
.ios-back { position: absolute; left: 13px; display: flex; gap: 4px; align-items: center; color: var(--ios-accent); font-size: 16px; }
.ios-back svg { width: 10px; height: 18px; stroke-width: 2.5; }
.ios-title { display: flex; align-items: center; gap: 8px; padding: 5px 13px 5px 6px; border-radius: 30px; background: var(--ios-fill); }
.ios-title b { font-size: 15px; font-weight: 600; }
.ios-menu { position: absolute; right: 17px; font-size: 13px; letter-spacing: 2px; color: var(--ios-accent); }
.ios-transcript { padding: 12px 20px; display: flex; flex-direction: column; align-items: flex-start; gap: 14px; flex: 1; min-height: 0; }
.ios-date { text-align: center; width: 100%; color: var(--ios-faint); font-size: 12px; margin: 4px 0 0; }
.ios-message { border-radius: 18px; padding: 10px 14px; max-width: 100%; font-size: 16px; line-height: 1.45; }
.ios-mine { align-self: flex-end; background: #e6cc5a; color: #2e3420; }
.ios-assistant { background: var(--ios-bubble); }
.ios-message code { color: inherit; font: .9em ui-monospace, 'SFMono-Regular', Menlo, monospace; padding: 0; background: none; }
.ios-gate { align-self: stretch; padding: 14px; border-radius: 16px; background: var(--ios-bubble); display: flex; flex-direction: column; gap: 10px; }
.ios-command { font: 600 16px/1.4 ui-monospace, 'SFMono-Regular', Menlo, monospace; overflow-wrap: anywhere; }
.ios-machine { font-size: 15px; color: var(--ios-muted); }
.ios-details { font-size: 12px; font-weight: 500; color: var(--ios-muted); display: flex; justify-content: space-between; align-items: center; }
.ios-details > span { font-size: 22px; color: var(--ios-accent); line-height: 12px; }
.ios-decision { position: relative; height: 21px; }
.ios-resolved { font-size: 13px; }
.ios-pending { display: none; flex-direction: column; align-items: flex-start; gap: 0; }
.ios-pending > span { display: flex; align-items: center; position: relative; min-height: 44px; font-size: 13px; font-weight: 600; padding: 7px 14px; isolation: isolate; }
.ios-pending > span::before { content: ''; position: absolute; z-index: -1; inset: 7px 0; border-radius: 30px; background: var(--ios-fill); }
.ios-pending .ios-allow { color: var(--ios-on-accent); }
.ios-pending .ios-allow::before { background: var(--ios-accent); }
.ios-tool { display: flex; align-items: center; gap: 6px; color: var(--ios-muted); font-size: 12px; padding: 0 8px; }
.ios-tool svg { width: 14px; height: 14px; }
.ios-tool .ios-check { color: var(--ios-success); }
.ios-tool > span { color: var(--ios-faint); }
.ios-composer { display: flex; align-items: center; gap: 6px; padding: 8px; margin: 0 16px 14px; border: 1px solid var(--ios-separator); border-radius: 22px; background: var(--ios-raised); box-shadow: 0 4px 12px #0000000a; flex: none; }
.ios-attach { display: grid; place-items: center; width: 32px; height: 32px; margin: 6px; background: var(--ios-fill); border-radius: 50%; font-size: 23px; }
.ios-placeholder { flex: 1; color: var(--ios-faint); font-size: 16px; white-space: nowrap; }
.ios-composer .ios-mic { width: 14px; height: 18px; margin: 0 9px; }
.ios-voice { display: grid; place-items: center; width: 32px; height: 32px; margin: 6px; border-radius: 50%; background: #e6cc5a; color: #2e3420; }
.ios-voice svg { width: 17px; height: 17px; stroke-width: 2; }
.ios-home { height: 22px; flex: none; display: flex; justify-content: center; align-items: flex-start; padding-top: 6px; }
.ios-home > span { height: 4px; width: 117px; background: var(--ios-ink); border-radius: 10px; }
.ios-app-mock :deep(.lemon-eyes) { animation: none; }
.armed .step { opacity: 0; }
.armed .ios-decision { height: 132px; }
.armed .ios-pending { display: flex; }
.armed .ios-resolved { position: absolute; inset: 0; visibility: hidden; }
.playing .step { animation: ios-appear .3s ease-out both; }
.playing .step-one { animation-delay: .15s; }
.playing .step-two { animation-delay: .9s; }
.playing .step-three { animation-delay: 1.65s; }
.playing .step-four { animation-delay: 3.8s; }
.playing .ios-decision { animation: ios-collapse .25s 3.2s forwards; }
.playing .ios-pending { animation: ios-resolve 0s 3.2s forwards; }
.playing .ios-resolved { animation: ios-resolved 0s 3.45s forwards; }
@keyframes ios-appear { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
@keyframes ios-collapse { to { height: 21px; } }
@keyframes ios-resolve { to { visibility: hidden; } }
@keyframes ios-resolved { to { visibility: visible; } }
@media (prefers-reduced-motion: reduce) { .ios-app-mock .step { opacity: 1; animation: none; } .ios-app-mock .ios-decision { height: 21px; animation: none; } .ios-app-mock .ios-pending { display: none; } .ios-app-mock .ios-resolved { position: static; visibility: visible; animation: none; } }
</style>

<style>
.dark .ios-app-mock { --ios-canvas: #121311; --ios-bubble: #22241f; --ios-raised: #252722; --ios-fill: rgb(255 255 255 / 7%); --ios-separator: rgb(255 255 255 / 8%); --ios-ink: #ecede6; --ios-muted: #a0a598; --ios-faint: #8a8f84; --ios-accent: #a3c9a9; --ios-on-accent: #14201a; --ios-success: #8ccb98; }
.dark .ios-app-mock .ios-composer { box-shadow: none; }
</style>
