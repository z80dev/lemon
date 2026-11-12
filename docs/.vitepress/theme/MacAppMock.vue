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
  <div ref="root" class="mac-app-mock" :class="{ armed, playing }" aria-hidden="true">
    <div class="mac-window">
      <aside class="mac-sidebar">
        <div class="mac-toolbar">
          <span class="mac-lights"><i /><i /><i /></span>
          <svg class="sidebar-toggle" viewBox="0 0 20 18"><rect x="1" y="2" width="18" height="14" rx="3"/><path d="M7 2v14"/></svg>
          <svg viewBox="0 0 20 20"><circle cx="8" cy="8" r="5"/><path d="m12 12 5 5"/></svg>
          <span class="mac-plus">+</span>
        </div>
        <div class="mac-pinned"><div class="mac-pinned-bot"><LemonFace :size="31" /><span>Lemon</span></div></div>
        <div class="mac-utility"><svg viewBox="0 0 20 20"><path d="M4 4h12l2 10v3H2v-3L4 4Zm-2 9h5l1 2h4l1-2h5"/></svg>Inbox</div>
        <div class="mac-utility"><svg viewBox="0 0 20 20"><path d="M3 6a8 8 0 1 1-1 7M3 2v5h5M10 5v5l3 2"/></svg>Activity</div>
        <div class="mac-section">Bots <span>⌄</span></div>
        <div class="mac-bot-row"><LemonFace color="green" :size="24"/><div><b>Sprout</b><small>Ready when you are.</small></div></div>
        <div class="mac-bot-row"><LemonFace color="blue" :size="24"/><div><b>Atlas</b><small>All caught up.</small></div></div>
        <div class="mac-account"><span class="mac-initials">Y</span><span class="mac-connect">Connect apps <svg viewBox="0 0 16 16"><rect x="2" y="2" width="4" height="4" rx="1"/><rect x="10" y="2" width="4" height="4" rx="1"/><rect x="2" y="10" width="4" height="4" rx="1"/><rect x="10" y="10" width="4" height="4" rx="1"/></svg></span></div>
      </aside>
      <div class="mac-conversation">
        <div class="mac-chat-header"><span class="mac-header-pill"><LemonFace :size="15"/><b>Lemon</b></span><span class="mac-overflow">•••</span></div>
        <div class="mac-transcript">
          <div class="mac-date">Today, 9:41 AM</div>
          <div class="mac-message mac-mine step step-one">Why is <code>upload_test</code> flaky?</div>
          <div class="mac-message mac-assistant step step-two">Two tests share <code>/tmp/uploads</code>.<br>I gave each its own temp dir.</div>
          <div class="mac-gate step step-three">
            <strong class="mac-command">mix test test/upload_test.exs</strong>
            <span class="mac-machine">Terminal on This Mac</span>
            <div class="mac-details">Details <span>›</span></div>
            <div class="mac-decision">
              <div class="mac-pending"><span class="mac-allow">Allow once</span><span>Allow Terminal for this chat</span><span>Deny</span></div>
              <div class="mac-resolved">Allowed once by you · 9:41 AM</div>
            </div>
          </div>
          <div class="mac-tool step step-four"><svg viewBox="0 0 18 18"><rect x="1" y="3" width="16" height="12" rx="2"/><path d="m4 6 3 3-3 3m5 0h4"/></svg><span>Run upload tests</span><svg class="mac-check" viewBox="0 0 18 18"><circle cx="9" cy="9" r="7"/><path d="m5 9 3 3 5-6"/></svg><span class="mac-duration">0.8s</span></div>
          <div class="mac-message mac-assistant mac-result step step-four">2 tests, 0 failures. All green.</div>
        </div>
        <div class="mac-composer"><span class="mac-attach">+</span><span class="mac-placeholder">Message Lemon</span><svg class="mac-mic" viewBox="0 0 18 20"><rect x="6" y="1" width="6" height="11" rx="3"/><path d="M3 8v2a6 6 0 0 0 12 0V8M9 16v3m-3 0h6"/></svg><span class="mac-voice"><svg viewBox="0 0 20 20"><path d="M3 8v4m4-7v10m3-13v16m3-13v10m4-7v4"/></svg></span></div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.mac-app-mock { --mac-canvas: #f8f8f4; --mac-sidebar: #f0f1e9; --mac-bubble: #ebece3; --mac-raised: #fff; --mac-fill: rgb(43 49 42 / 6%); --mac-selected: rgb(43 49 42 / 8.5%); --mac-separator: rgb(43 49 42 / 9%); --mac-ink: #2b312a; --mac-muted: #5a6257; --mac-faint: #676f64; --mac-accent: #3c6248; --mac-on-accent: #fff; --mac-success: #3b7347; width: 100%; height: 280px; display: flex; align-items: center; container-type: inline-size; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif; font-size: 8px; line-height: 1.4; color: var(--mac-ink); text-align: left; }
.mac-app-mock * { box-sizing: border-box; }
.mac-app-mock svg { display: block; flex: none; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; width: 12px; height: 12px; }
.mac-window { display: flex; width: 100%; height: 266px; overflow: hidden; border: 1px solid var(--mac-separator); border-radius: 10px; background: var(--mac-canvas); box-shadow: 0 9px 24px #0000000c, 0 1px 3px #00000012; }
.mac-sidebar { width: 26%; min-width: 76px; flex: none; display: flex; flex-direction: column; background: var(--mac-sidebar); border-right: 1px solid var(--mac-separator); }
.mac-toolbar { height: 31px; display: flex; align-items: center; gap: 7px; padding: 0 8px; flex: none; }
.mac-lights { display: flex; gap: 3px; margin-right: auto; }
.mac-lights i { width: 6px; height: 6px; border-radius: 50%; background: #ff5f57; box-shadow: inset 0 0 0 .5px #0002; }
.mac-lights i:nth-child(2) { background: #febc2e; }
.mac-lights i:nth-child(3) { background: #28c840; }
.mac-toolbar svg { width: 10px; height: 10px; color: var(--mac-muted); }
.mac-toolbar .sidebar-toggle { width: 11px; }
.mac-plus { font-size: 14px; font-weight: 300; color: var(--mac-muted); }
.mac-pinned { padding: 4px 6px 8px; }
.mac-pinned-bot { width: 49px; padding: 6px 0 5px; border-radius: 8px; background: var(--mac-selected); display: flex; flex-direction: column; align-items: center; gap: 3px; font-size: 7px; }
.mac-utility { display: flex; align-items: center; gap: 7px; padding: 4px 11px; font-size: 7.5px; }
.mac-utility svg { color: var(--mac-muted); width: 10px; height: 10px; }
.mac-section { color: var(--mac-muted); display: flex; justify-content: space-between; margin: 12px 12px 3px; font-size: 6.8px; font-weight: 500; }
.mac-bot-row { display: flex; gap: 5px; align-items: center; padding: 6px 8px; overflow: hidden; }
.mac-bot-row > div { min-width: 0; }
.mac-bot-row b { font-size: 7.5px; font-weight: 600; }
.mac-bot-row small { display: block; color: var(--mac-muted); font-size: 6.4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mac-account { display: flex; align-items: center; gap: 5px; padding: 8px; margin-top: auto; }
.mac-initials { display: grid; place-items: center; width: 17px; height: 17px; border-radius: 50%; background: var(--mac-fill); font-size: 7px; flex: none; }
.mac-connect { display: flex; align-items: center; justify-content: center; gap: 5px; border-radius: 20px; border: 1px solid var(--mac-separator); background: var(--mac-raised); padding: 5px 6px; font-size: 6.4px; font-weight: 600; white-space: nowrap; flex: 1; }
.mac-connect svg { width: 7px; height: 7px; }
.mac-conversation { min-width: 0; flex: 1; display: flex; flex-direction: column; }
.mac-chat-header { position: relative; height: 34px; flex: none; display: flex; justify-content: center; align-items: center; }
.mac-header-pill { display: flex; align-items: center; gap: 5px; padding: 3px 9px 3px 4px; border-radius: 40px; background: var(--mac-raised); box-shadow: 0 2px 7px #0000000d; }
.mac-header-pill b { font-size: 8px; font-weight: 600; }
.mac-overflow { position: absolute; right: 8px; top: 8px; background: var(--mac-fill); width: 18px; height: 18px; display: grid; place-items: center; border-radius: 50%; font-size: 7px; letter-spacing: 1px; }
.mac-transcript { padding: 0 11px; display: flex; flex-direction: column; gap: 4px; flex: 1; min-height: 0; }
.mac-date { text-align: center; color: var(--mac-faint); font-size: 6.2px; margin-bottom: 2px; }
.mac-message { border-radius: 10px; padding: 6px 8px; width: fit-content; max-width: 94%; font-size: clamp(7.3px, 1.95cqw, 8px); line-height: 1.45; }
.mac-mine { background: #e6cc5a; color: #2e3420; align-self: flex-end; }
.mac-assistant { background: var(--mac-bubble); }
.mac-message code { font: .95em ui-monospace, 'SFMono-Regular', Menlo, monospace; background: none; padding: 0; color: inherit; }
.mac-gate { background: var(--mac-bubble); padding: 7px 8px; border-radius: 9px; display: flex; flex-direction: column; gap: 4px; }
.mac-command { font: 600 clamp(6.6px, 1.8cqw, 8px)/1.4 ui-monospace, 'SFMono-Regular', Menlo, monospace; overflow-wrap: anywhere; }
.mac-machine { color: var(--mac-muted); font-size: 6.8px; }
.mac-details { color: var(--mac-muted); display: flex; justify-content: space-between; font-size: 6.6px; font-weight: 500; }
.mac-details > span { color: var(--mac-accent); font-size: 10px; line-height: 9px; }
.mac-decision { position: relative; min-height: 12px; }
.mac-resolved { font-size: 6.8px; }
.mac-pending { display: none; flex-wrap: wrap; gap: 3px; font-size: 5.9px; font-weight: 600; }
.mac-pending > span { border-radius: 20px; padding: 3px 5px; background: var(--mac-fill); white-space: nowrap; }
.mac-pending .mac-allow { background: var(--mac-accent); color: var(--mac-on-accent); }
.mac-tool { display: flex; align-items: center; gap: 4px; color: var(--mac-muted); font-size: 6.5px; padding: 1px 4px; }
.mac-tool svg { width: 9px; height: 9px; }
.mac-tool .mac-check { color: var(--mac-success); }
.mac-duration { color: var(--mac-faint); }
.mac-result { padding-top: 5px; padding-bottom: 5px; }
.mac-composer { display: flex; align-items: center; gap: 6px; border: 1px solid var(--mac-separator); background: var(--mac-raised); border-radius: 14px; box-shadow: 0 2px 8px #00000008; padding: 4px; margin: 7px 10px 9px; flex: none; }
.mac-attach { border-radius: 50%; background: var(--mac-fill); width: 18px; height: 18px; display: grid; place-items: center; font-size: 13px; }
.mac-placeholder { flex: 1; color: var(--mac-faint); font-size: 7.5px; }
.mac-composer .mac-mic { width: 9px; height: 11px; }
.mac-voice { background: #e6cc5a; color: #2e3420; width: 18px; height: 18px; display: grid; place-items: center; border-radius: 50%; }
.mac-voice svg { width: 11px; height: 11px; stroke-width: 2; }
.mac-app-mock :deep(.lemon-eyes) { animation: none; }
.armed .step { opacity: 0; }
.armed .mac-decision { height: 30px; }
.armed .mac-pending { display: flex; position: absolute; inset: 0; }
.armed .mac-resolved { visibility: hidden; position: absolute; inset: 0; }
.playing .step { animation: mac-appear .3s ease-out both; }
.playing .step-one { animation-delay: .15s; }
.playing .step-two { animation-delay: .9s; }
.playing .step-three { animation-delay: 1.65s; }
.playing .step-four { animation-delay: 3.8s; }
.playing .mac-decision { animation: mac-collapse .25s 3.2s forwards; }
.playing .mac-pending { animation: mac-resolve 0s 3.2s forwards; }
.playing .mac-resolved { animation: mac-resolved 0s 3.2s forwards; }
@keyframes mac-appear { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; transform: translateY(0); } }
@keyframes mac-collapse { to { height: 12px; } }
@keyframes mac-resolve { to { visibility: hidden; } }
@keyframes mac-resolved { to { visibility: visible; } }
@container (max-width: 340px) { .mac-toolbar { gap: 5px; padding: 0 6px; } .mac-toolbar .sidebar-toggle { display: none; } .mac-connect { font-size: 5.5px; padding-inline: 4px; gap: 3px; } .mac-account { gap: 4px; padding-inline: 5px; } .mac-transcript { padding-inline: 8px; } }
@media (prefers-reduced-motion: reduce) { .mac-app-mock .step { opacity: 1; animation: none; } .mac-app-mock .mac-decision { height: auto; animation: none; } .mac-app-mock .mac-pending { display: none; } .mac-app-mock .mac-resolved { position: static; visibility: visible; animation: none; } }
</style>

<style>
.dark .mac-app-mock { --mac-canvas: #121311; --mac-sidebar: #181916; --mac-bubble: #22241f; --mac-raised: #252722; --mac-fill: rgb(255 255 255 / 7%); --mac-selected: rgb(255 255 255 / 8.5%); --mac-separator: rgb(255 255 255 / 8%); --mac-ink: #ecede6; --mac-muted: #a0a598; --mac-faint: #8a8f84; --mac-accent: #a3c9a9; --mac-on-accent: #14201a; --mac-success: #8ccb98; }
.dark .mac-app-mock .mac-header-pill, .dark .mac-app-mock .mac-composer { box-shadow: none; }
</style>
