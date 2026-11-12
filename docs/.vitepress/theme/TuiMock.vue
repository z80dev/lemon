<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'

const root = ref(null)
// SSR and above-the-fold visitors see the completed session, never an empty stage.
const stage = ref(6)
const playing = ref(false)
const timers = []
let observer
const rule = '─'.repeat(70)
const question = 'Why is upload_test flaky?'
const wordmark = ['', '█', '█ ▄██▄ █▀▄▀▄ ▄▀▀▄ █▀▀▄', '█ ▀▄▄▄ █ █ █ ▀▄▄▀ █  █', 'tui 2026.11.6', '/help · Ctrl+P commands · Ctrl+X sessions', 'Ctrl+O model · Ctrl+C abort/quit']

// The shipping Banner's 24 × 14 pixels and half-block paint algorithm.
const art = [
  '..................LLLL..', '...............LLLLLL...',
  '.........######LLL......', '......############......',
  '.....##############.....', '....####hhhh########....',
  '...###hh#############...', '########################',
  '########################', '...##################...',
  '....################....', '.....##############.....',
  '......############......', '.........######.........',
]
function mix(stops, t) {
  const segment = Math.min(1, Math.max(0, t)) * (stops.length - 1)
  const index = Math.min(stops.length - 2, Math.floor(segment))
  const a = parseInt(stops[index].slice(1), 16)
  const b = parseInt(stops[index + 1].slice(1), 16)
  return '#' + [16, 8, 0].map(shift => {
    const from = (a >> shift) & 255
    return Math.round(from + (((b >> shift) & 255) - from) * (segment - index)).toString(16).padStart(2, '0')
  }).join('')
}
const pixels = art.map((line, y) => [...line].map((kind, x) => {
  if (kind === '#') return mix(['#fff27a', '#ffcf1a', '#ff9f1c'], (x / 23 + Math.floor(y / 2) / 6) / 2)
  if (kind === 'h') return '#fffdeb'
  if (kind === 'L') return mix(['#4caf50', '#c8f07a'], (x - 15) / 6)
  return undefined
}))
const logoRows = Array.from({ length: 7 }, (_, row) => Array.from({ length: 24 }, (_, x) => {
  const top = pixels[row * 2][x]
  const bottom = pixels[row * 2 + 1][x]
  return {
    glyph: !top && !bottom ? ' ' : !bottom ? '▀' : !top ? '▄' : top === bottom ? '█' : '▀',
    color: top || bottom,
    background: top && bottom && top !== bottom ? bottom : undefined,
  }
}))
const approvalRows = [
  ['approval required · bash', 'warning'],
  ['mix test test/upload_test.exs', ''],
  ['uploads · expires in 1m00s', 'dim'],
  ['❯ 1  allow once', 'accent'],
  ['  2  allow for this session', ''],
  ['  3  allow always', ''],
  ['  4  deny', 'error'],
  ['1-4 picks · ↑↓ then enter · esc denies', 'dim'],
]
function play() {
  playing.value = true
  stage.value = 1
  for (const [delay, next] of [[1500, 2], [1850, 3], [3450, 4], [4950, 5], [6550, 6]]) {
    timers.push(setTimeout(() => { stage.value = next }, delay))
  }
}
onMounted(() => {
  const element = root.value
  if (!element || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
  const bounds = element.getBoundingClientRect()
  if (bounds.top < window.innerHeight && bounds.bottom > 0 && bounds.left < window.innerWidth && bounds.right > 0) return
  stage.value = 0
  observer = new IntersectionObserver(entries => {
    if (!entries.some(entry => entry.isIntersecting && entry.intersectionRatio >= 0.4)) return
    observer.disconnect()
    play()
  }, { threshold: 0.4 })
  observer.observe(element)
})
onBeforeUnmount(() => {
  observer?.disconnect()
  timers.forEach(clearTimeout)
})
</script>

<template>
  <div ref="root" class="tui-mock" :class="{ 'tui-mock--playing': playing }" aria-hidden="true">
    <div class="terminal-chrome">
      <span class="traffic-lights"><i /><i /><i /></span>
      <span>lemon — 72 × 22</span>
      <span class="chrome-spacer" />
    </div>
    <div class="terminal-screen">
      <div class="scroll-region">
        <div class="scrollback">
          <div class="banner">
            <div v-for="(row, y) in logoRows" :key="y" class="terminal-row banner-row"><span class="banner-gutter" /><span v-for="(cell, x) in row" :key="x" class="pixel" :style="{ color: cell.color, backgroundColor: cell.background }">{{ cell.glyph }}</span><span class="banner-gap" /><span :class="y < 4 ? 'accent wordmark' : y === 4 ? 'muted' : 'dim'">{{ wordmark[y] }}</span></div>
          </div>
          <div class="conversation">
            <div class="terminal-row"> </div>
            <div class="terminal-row" :class="{ invisible: stage < 2 }"><span class="info">❯</span> {{ question }}</div>
            <div class="terminal-row"> </div>
            <div :class="{ invisible: stage < 3, streaming: playing && stage === 3 }">
              <div class="terminal-row answer-first"> Both tests share <span class="accent">/tmp/uploads</span>.</div>
              <div class="terminal-row answer-second"> I gave each its own temp dir.</div>
            </div>
            <div class="terminal-row"> </div>
            <div v-if="stage >= 5" class="terminal-row success"> · approval granted for bash (once)</div>
            <div v-if="stage >= 5" class="tool">
              <div class="terminal-row tool-heading"><span :class="stage === 5 ? 'accent spinner' : 'success'">{{ stage === 5 ? '⠋' : '✓' }}</span><span class="tool-title">`mix test test/upload_test.exs`</span><span class="dim"> (command)</span><span class="elapsed dim">{{ stage === 5 ? '800ms' : '1.2s' }}</span></div>
              <div v-if="stage === 5" class="terminal-row muted">  mix test test/upload_test.exs</div>
              <template v-else>
                <div class="terminal-row muted">  [0] 2 tests, 0 failures</div>
                <div class="terminal-row muted">  [0] Success</div>
                <div class="terminal-row muted">  2 tests, 0 failures</div>
              </template>
            </div>
          </div>
        </div>
      </div>
      <div v-if="stage === 4" class="approval-panel">
        <div class="terminal-row warning">╭{{ rule }}╮</div>
        <div v-for="([text, tone], index) in approvalRows" :key="index" class="terminal-row"><span class="border">│ </span><span :class="tone">{{ text.padEnd(68, ' ') }}</span><span class="border"> │</span></div>
        <div class="terminal-row border">╰{{ rule }}╯</div>
      </div>
      <div class="dock">
        <div class="terminal-row"> </div>
        <div class="terminal-row"><span class="accent">claude-sonnet-4</span><span class="dim"> · </span><span class="muted">[░░░░░░░░] 2% 4k/200k</span><span class="dim"> · {{ stage > 1 && stage < 6 ? 'working' : 'idle' }} · </span><span class="muted">main</span><span class="dim"> · queue</span><template v-if="stage < 2 || stage === 6"><span class="dim"> · </span><span class="muted">uploads</span></template></div>
        <div class="terminal-row border">╭{{ rule }}╮</div>
        <div class="terminal-row editor-row"><span class="border">╰─ </span><span v-if="stage === 1" class="typed-question">{{ question }}</span><span class="caret">▏</span><span class="editor-fill" /><span class="border"> ─╯</span></div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tui-mock {
  width: 100%;
  height: 280px;
  overflow: hidden;
  container-type: inline-size;
  border: 1px solid #343941;
  border-radius: 8px;
  background: #111318;
  color: #e6e6e6;
  text-align: left;
  color-scheme: dark;
  box-shadow: 0 7px 20px #00000014;
}
.terminal-chrome {
  height: 26px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 10px;
  border-bottom: 1px solid #343941;
  background: #25282e;
  color: #9aa0a6;
  font: 9px/1 'JetBrains Mono Variable', monospace;
}
.traffic-lights { display: flex; gap: 4px; width: 32px; }
.traffic-lights i { width: 6px; height: 6px; border-radius: 50%; background: #ff5f57; }
.traffic-lights i:nth-child(2) { background: #febc2e; }
.traffic-lights i:nth-child(3) { background: #28c840; }
.chrome-spacer { width: 32px; }
.terminal-screen {
  height: calc(100% - 26px);
  display: flex;
  flex-direction: column;
  padding: 10px 9px 9px;
  font-family: 'JetBrains Mono Variable', 'JetBrains Mono', monospace;
  font-size: min(10.5px, calc(2.2cqw - .3px));
  line-height: 1.05;
  font-weight: 400;
  font-variant-ligatures: none;
  letter-spacing: 0;
  -webkit-font-smoothing: antialiased;
}
.terminal-row { height: 1.05em; min-height: 1.05em; white-space: pre; }
.scroll-region { flex: 1; min-height: 0; overflow: hidden; display: flex; flex-direction: column; justify-content: flex-end; }
.scrollback { flex-shrink: 0; min-height: 100%; display: flex; flex-direction: column; }
.banner-row { display: flex; line-height: 1em; height: 1em; min-height: 1em; }
.banner-gutter, .pixel { flex: 0 0 1ch; width: 1ch; }
.banner-gap { flex: 0 0 3ch; width: 3ch; }
.wordmark { font-weight: 700; }
.accent { color: #f2c94c; }
.info { color: #79b8ff; }
.success { color: #7ec97e; }
.muted { color: #9aa0a6; }
.dim { color: #6b7178; }
.border { color: #3a3f46; }
.warning { color: #e8b64c; }
.error { color: #f07178; }
.tool-title { color: #c8a2f5; }
.tool-heading, .editor-row { display: flex; width: 72ch; }
.tool-heading > :first-child { width: 1ch; margin-right: 1ch; }
.elapsed { margin-left: auto; }
.editor-fill { flex: 1; }
.caret { color: #e6e6e6; }
.invisible { visibility: hidden; }
.typed-question { display: inline-block; overflow: hidden; animation: tui-type 1.2s steps(25, end) both; }
.streaming .terminal-row { overflow: hidden; width: 0; animation: tui-stream .7s steps(30, end) forwards; }
.streaming .answer-second { animation-delay: .7s; }
.spinner { position: relative; color: transparent; }
.spinner::after { position: absolute; left: 0; color: #f2c94c; content: '⠋'; animation: tui-spin .8s steps(1, end) infinite; }
@keyframes tui-type { from { width: 0; } to { width: 25ch; } }
@keyframes tui-stream { to { width: 32ch; } }
@keyframes tui-spin { 10% { content: '⠙'; } 20% { content: '⠹'; } 30% { content: '⠸'; } 40% { content: '⠼'; } 50% { content: '⠴'; } 60% { content: '⠦'; } 70% { content: '⠧'; } 80% { content: '⠇'; } 90% { content: '⠏'; } }
@media (prefers-reduced-motion: reduce) {
  .typed-question, .streaming .terminal-row, .spinner::after { animation: none; }
}
</style>
