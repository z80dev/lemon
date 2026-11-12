<script setup>
// A scripted Lemon Bot conversation for the home page. Each example plays as a
// timeline of steps; time only advances while the demo is on screen and not
// paused, and reduced-motion visitors get each conversation's final state.
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import LemonFace from './LemonFace.vue'

const emit = defineEmits(['mood'])

const scenarios = [
  {
    label: 'Fix a bug',
    color: 'green',
    day: 'Today 2:14 PM',
    steps: [
      { do: 'type', text: 'upload_test is flaky again. Can you take a look?' },
      { do: 'think', ms: 1000 },
      { do: 'say', text: 'On it. I’ll send a helper through the last CI log while I read the test.' },
      { do: 'agents', crew: [{ color: 'green', name: 'helper', task: 'reading ci.log', result: 'both failures touch /tmp/uploads', ms: 2600 }] },
      { do: 'say', text: 'Found it: two tests share `/tmp/uploads`. I gave each its own temp dir. Let me prove it:' },
      { do: 'approve', tool: 'Terminal', command: 'mix test test/upload_test.exs' },
      { do: 'output', lines: ['............', 'Finished in 1.9 seconds', '12 tests, 0 failures'] },
      { do: 'say', text: 'All green. The fix is on `fix/upload-tmp-dir`. Open a PR?', mood: 'joy' },
    ],
    denied: 'No problem, I won’t run it. The fix is waiting on `fix/upload-tmp-dir` whenever you want to check it.',
  },
  {
    label: 'Remember',
    color: 'blue',
    day: 'Today 8:02 AM',
    steps: [
      { do: 'say', text: 'Morning ☀️ CI stayed green overnight, and your release-notes draft is ready for a look.' },
      { do: 'type', text: 'What did we decide about outbox retries?' },
      { do: 'think', ms: 700 },
      { do: 'agents', crew: [{ color: 'blue', name: 'memory', task: 'searching notes', result: 'Tuesday · design call', ms: 1800 }] },
      { do: 'say', text: 'Tuesday’s call: retry unknown outcomes at-least-once, bounded, with the same idempotency key. A rare duplicate beats a lost message.' },
      { do: 'type', text: 'Perfect. Remind me Friday to write it up.' },
      { do: 'think', ms: 700 },
      { do: 'remind', when: 'Fri 9:00', what: 'Write up the outbox retry policy' },
      { do: 'say', text: 'Done. I’ll nudge you Friday at 9.', mood: 'joy' },
    ],
  },
  {
    label: 'Delegate',
    color: 'purple',
    day: 'Today 4:37 PM',
    steps: [
      { do: 'type', text: 'Review PR #412 for security, tests, and docs.' },
      { do: 'think', ms: 800 },
      { do: 'say', text: 'Splitting it three ways. Back in a sec.' },
      { do: 'agents', crew: [
        { color: 'pink', name: 'security', task: 'auditing auth paths', result: 'no findings', ms: 3200 },
        { color: 'green', name: 'tests', task: 'running affected suites', result: '214 passed', ms: 2300 },
        { color: 'purple', name: 'docs', task: 'checking the changelog', result: 'entry missing', ms: 1500 },
      ] },
      { do: 'say', text: 'Security and tests are clean. One thing before merge: the changelog entry is missing. Want me to draft it?', mood: 'wink' },
    ],
  },
]

const PHASE_MOODS = { idle: 'happy', typing: 'happy', thinking: 'surprised', speaking: 'happy', working: 'wink', asking: 'surprised' }
const CANCEL = Symbol('cancel')

const root = ref(null)
const windowEl = ref(null)
const scroller = ref(null)
const active = ref(0)
const log = ref([])
const draft = ref('')
const sent = ref(false)
const phase = ref('idle')
const doneMood = ref('joy')
const working = ref(0)
const progress = ref(0)
const allowance = ref(false)
const userPaused = ref(false)
const inView = ref(false)
const cursor = reactive({ x: 0, y: 0, show: false, down: false })

const mood = computed(() => (phase.value === 'done' ? doneMood.value : PHASE_MOODS[phase.value]))
const status = computed(() => {
  if (phase.value === 'asking') return 'Waiting for you'
  if (phase.value === 'speaking') return 'Writing a reply'
  if (phase.value === 'working' && working.value) return 'Working'
  if (phase.value === 'working') return 'Running command'
  return 'Thinking'
})
watch(mood, (value) => emit('mood', value))
watch(log, follow, { deep: true, flush: 'post' })

let generation = 0
let reduced = false
let answer = null
let observer

function wait(ms) {
  if (reduced) return Promise.resolve()
  const gen = generation
  return new Promise((resolve, reject) => {
    let left = ms
    let last = performance.now()
    const tick = (now) => {
      if (gen !== generation) return reject(CANCEL)
      if (!userPaused.value && inView.value) left -= now - last
      last = now
      if (left <= 0) resolve()
      else requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })
}

function follow() {
  const el = scroller.value
  if (el) el.scrollTo({ top: el.scrollHeight, behavior: reduced ? 'auto' : 'smooth' })
}

let uid = 0
function push(entry) {
  log.value.push({ id: ++uid, ...entry })
  return log.value.at(-1)
}

function segments(text, shown) {
  const out = []
  let position = 0
  for (const part of text.split(/(`[^`]+`)/)) {
    if (!part) continue
    const code = part.startsWith('`')
    const visible = Math.max(0, Math.min(part.length, shown - position))
    position += part.length
    if (!visible) break
    out.push(code ? { code, text: part.slice(1, Math.min(visible, part.length - 1)) } : { code, text: part.slice(0, visible) })
  }
  return out
}

async function type(step) {
  phase.value = 'typing'
  if (!reduced) {
    await wait(450)
    for (let i = 1; i <= step.text.length; i++) {
      draft.value = step.text.slice(0, i)
      await wait(22 + ((i * 37) % 43))
    }
    await wait(380)
    sent.value = true
  }
  push({ kind: 'user', text: step.text })
  draft.value = ''
  await wait(200)
  sent.value = false
}

async function think(step) {
  phase.value = 'thinking'
  if (reduced) return
  const bubble = push({ kind: 'think' })
  await wait(step.ms)
  log.value = log.value.filter((item) => item.id !== bubble.id)
}

async function say(step) {
  phase.value = 'speaking'
  const message = push({ kind: 'bot', text: step.text, shown: reduced ? step.text.length : 0 })
  if (!reduced) {
    await wait(160)
    for (const word of step.text.match(/\S+\s*/g)) {
      message.shown += word.length
      await wait(38 + word.length * 7)
    }
  }
  doneMood.value = step.mood || 'happy'
  await wait(650)
}

async function agents(step) {
  phase.value = 'working'
  const card = push({ kind: 'agents', crew: step.crew.map((agent) => ({ ...agent, done: reduced })) })
  if (reduced) return
  working.value = step.crew.length
  await wait(350)
  await Promise.all(card.crew.map(async (agent) => {
    await wait(agent.ms)
    agent.done = true
    working.value -= 1
  }))
  await wait(600)
}

function aim(selector) {
  const target = windowEl.value?.querySelector(selector)
  if (!target) return
  const frame = windowEl.value.getBoundingClientRect()
  const box = target.getBoundingClientRect()
  cursor.x = box.left - frame.left + box.width * 0.42
  cursor.y = box.top - frame.top + box.height * 0.55
}

function choose(card, choice, byUser = false) {
  if (card.choice || answer?.card !== card) return
  card.choice = choice
  answer.resolve(choice)
  // Keep keyboard focus in the conversation once the pressed button is replaced by the verdict.
  if (byUser) setTimeout(() => windowEl.value?.querySelector('.verdict')?.focus({ preventScroll: true }), 260)
}

async function autoApprove(card) {
  await wait(1700)
  if (card.choice) return
  const frame = windowEl.value.getBoundingClientRect()
  cursor.x = frame.width - 70
  cursor.y = frame.height - 30
  cursor.show = true
  await wait(60)
  aim('.approve .once')
  await wait(950)
  if (card.choice) return
  cursor.down = true
  card.pressing = 'once'
  await wait(170)
  cursor.down = false
  card.pressing = ''
  choose(card, 'once')
}

async function approve(step) {
  phase.value = 'asking'
  const card = push({ kind: 'approve', tool: step.tool, command: step.command, choice: reduced ? 'once' : null, pressing: '' })
  if (reduced) return 'once'
  const choice = await new Promise((resolve, reject) => {
    answer = { card, resolve, reject }
    autoApprove(card).catch(reject)
  })
  answer = null
  await wait(260)
  cursor.show = false
  if (choice === 'chat') allowance.value = true
  await wait(500)
  return choice
}

async function output(step) {
  phase.value = 'working'
  const block = push({ kind: 'output', command: log.value.findLast((item) => item.kind === 'approve')?.command, lines: [] })
  for (const line of step.lines) {
    if (reduced) { block.lines.push(line); continue }
    if (/^·+$/.test(line)) {
      block.lines.push('')
      for (let i = 0; i < line.length; i++) {
        block.lines[block.lines.length - 1] += '·'
        await wait(55)
      }
    } else {
      await wait(320)
      block.lines.push(line)
    }
  }
  await wait(700)
}

async function remind(step) {
  phase.value = 'working'
  push({ kind: 'remind', when: step.when, what: step.what })
  await wait(700)
}

const actions = { type, think, say, agents, approve, output, remind }

async function play(index) {
  generation += 1
  answer?.reject(CANCEL)
  answer = null
  active.value = index
  log.value = []
  draft.value = ''
  sent.value = false
  allowance.value = false
  working.value = 0
  progress.value = 0
  cursor.show = false
  cursor.down = false
  phase.value = 'idle'
  const scenario = scenarios[index]
  try {
    push({ kind: 'divider', text: scenario.day })
    await wait(750)
    for (const [i, step] of scenario.steps.entries()) {
      const result = await actions[step.do](step)
      progress.value = (i + 1) / scenario.steps.length
      if (result === 'deny') {
        await say({ text: scenario.denied, mood: 'happy' })
        progress.value = 1
        break
      }
    }
    phase.value = 'done'
    await wait(5200)
    if (!reduced) play((index + 1) % scenarios.length)
  } catch (error) {
    if (error !== CANCEL) throw error
  }
}

onMounted(() => {
  reduced = matchMedia('(prefers-reduced-motion: reduce)').matches
  observer = new IntersectionObserver(([entry]) => { inView.value = entry.isIntersecting }, { threshold: 0.2 })
  observer.observe(root.value)
  play(0)
})

onBeforeUnmount(() => {
  generation += 1
  answer?.reject(CANCEL)
  observer?.disconnect()
})
</script>

<template>
  <div ref="root" class="chat-demo" :class="{ paused: userPaused }" role="region" aria-label="Example conversations with Lemon Bot">
    <div ref="windowEl" class="window">
      <div class="browser-chrome" aria-hidden="true">
        <div class="browser-tabs"><span class="traffic"><i></i><i></i><i></i></span><span class="browser-tab"><LemonFace :size="12" />Lemon Bot<span>×</span></span><span class="new-tab">+</span></div>
        <div class="browser-toolbar"><svg viewBox="0 0 16 16" width="13" height="13"><path d="m8 3-5 5 5 5M3 8h10" /></svg><svg class="browser-forward" viewBox="0 0 16 16" width="13" height="13"><path d="m8 3 5 5-5 5M3 8h10" /></svg><span class="address"><svg viewBox="0 0 16 16" width="11" height="11"><circle cx="8" cy="8" r="5.5"/><path d="M8 7v4M8 4.5v.5"/></svg>http://127.0.0.1:4100</span><span>⋮</span></div>
      </div>
      <div class="conversation">
        <header class="bar">
          <span class="header-icon back" aria-hidden="true"><svg viewBox="0 0 24 24" width="16" height="16"><path d="m15 18-6-6 6-6" /></svg></span>
          <div class="who"><LemonFace :size="22" /><b>Lemon</b><span v-if="!['idle', 'done', 'typing'].includes(phase)" class="working-dot" aria-hidden="true"></span></div>
          <span class="header-icon menu" aria-hidden="true"><svg viewBox="0 0 24 24" width="15" height="15"><circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/></svg></span>
          <Transition name="pop">
            <span v-if="allowance" class="allow-chip">Terminal allowed for this chat · <button type="button" @click="allowance = false">Stop allowing</button></span>
          </Transition>
        </header>

      <Transition name="swap" mode="out-in">
        <div ref="scroller" :key="active" class="log" role="log" aria-label="Example conversation transcript" aria-live="polite" aria-relevant="additions text">
          <TransitionGroup name="msg">
            <div v-for="item in log" :key="item.id" class="row" :class="`row-${item.kind}`">
              <span v-if="item.kind === 'divider'" class="divider">{{ item.text }}</span>
              <div v-else-if="item.kind === 'user'" class="bubble me"><span class="sr-only">You: </span>{{ item.text }}</div>

              <template v-else-if="item.kind === 'bot' || item.kind === 'think'">
                <div v-if="item.kind === 'think'" class="bubble them dots"><span class="sr-only">Lemon is thinking</span><i></i><i></i><i></i></div>
                <div v-else class="bubble them">
                  <span class="sr-only">Lemon: </span>
                  <template v-for="(part, index) in segments(item.text, item.shown)" :key="index">
                    <code v-if="part.code">{{ part.text }}</code><template v-else>{{ part.text }}</template>
                  </template>
                  <i v-if="item.shown < item.text.length" class="stream-caret"></i>
                </div>
              </template>

              <div v-else-if="item.kind === 'agents'" class="crew">
                <div v-for="agent in item.crew" :key="agent.name" class="agent" :class="{ done: agent.done }">
                  <svg viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" /></svg>
                  <span class="agent-text">{{ agent.name }} · {{ agent.done ? agent.result : agent.task }}</span>
                  <span v-if="!agent.done" class="spinner" aria-label="Working"></span>
                  <svg class="chevron" viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg>
                </div>
              </div>

              <div v-else-if="item.kind === 'approve'" class="approve">
                <div class="approve-heading"><h3>Command</h3><span class="badge">Commands</span></div>
                <pre><code>{{ item.command }}</code></pre>
                <p class="approve-target">Terminal on Studio Mac</p>
                <details class="approve-details">
                  <summary>Details</summary>
                  <p>Run the upload tests</p><p>Bot: Lemon</p><p>Scope: once</p><p>Review: Ask first · Ask</p><p>Origin: owner_chat</p>
                  <ul><li>Runs a local command</li></ul>
                  <dl><dt>command</dt><dd><pre><code>{{ item.command }}</code></pre></dd></dl>
                  <div class="gate-state"><span class="badge">{{ !item.choice ? 'Pending' : item.choice === 'deny' ? 'Denied' : 'Approved' }}</span><span>Expires 2:15 PM</span>
                    <p v-if="item.choice === 'deny'">No action was authorized. Ask the Bot for a new request if needed.</p>
                    <p v-else-if="item.choice">Permission granted only. This is not proof the proposed action completed.</p>
                  </div>
                </details>
                <Transition name="flip" mode="out-in">
                  <div v-if="!item.choice" class="choices">
                    <button type="button" class="once" :class="{ pressed: item.pressing === 'once' }" @click="choose(item, 'once', true)">Allow once</button>
                    <button type="button" class="chat" @click="choose(item, 'chat', true)">Allow {{ item.tool }} for this chat</button>
                    <button type="button" class="deny" @click="choose(item, 'deny', true)">Deny</button>
                  </div>
                  <p v-else class="verdict" :class="item.choice" tabindex="-1">
                    <template v-if="item.choice === 'deny'">Denied by you</template>
                    <template v-else-if="item.choice === 'chat'">Allowed for this chat by you</template>
                    <template v-else>Allowed once by you</template>
                    · 2:14 PM
                  </p>
                </Transition>
              </div>

              <div v-else-if="item.kind === 'output'" class="tool-result">
                <div class="tool-summary"><svg viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/></svg><span>Run upload tests</span><svg class="chevron open" viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg></div>
                <pre class="out">{{ item.command }}
<template v-for="(line, index) in item.lines" :key="index">{{ line }}
</template></pre>
              </div>

              <div v-else-if="item.kind === 'remind'" class="remind">
                <span>Reminder set · {{ item.when }} · {{ item.what }}</span>
              </div>
            </div>
          </TransitionGroup>
        </div>
      </Transition>

      <footer class="dock">
        <div v-if="['thinking', 'speaking', 'working', 'asking'].includes(phase)" class="activity" :class="{ asking: phase === 'asking' }" aria-hidden="true">
          <svg v-if="phase === 'asking'" class="hand" viewBox="0 0 24 24" width="12" height="12"><path d="M18 11V6a2 2 0 0 0-4 0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg><span v-else class="activity-dots"><i></i><i></i><i></i></span>
          <span>{{ status }}</span><span class="stop"><svg viewBox="0 0 12 12" width="8" height="8"><rect x="2" y="2" width="8" height="8" rx="1" fill="currentColor"/></svg>Stop</span>
        </div>
        <div class="composer" aria-hidden="true">
          <span class="add"><svg viewBox="0 0 24 24" width="17" height="17"><path d="M12 5v14M5 12h14"/></svg></span>
          <div class="field">
            <span v-if="draft">{{ draft }}<i class="caret"></i></span>
            <span v-else class="placeholder">Message Lemon</span>
          </div>
          <span class="mic"><svg viewBox="0 0 24 24" width="17" height="17"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8"/></svg></span>
          <span class="send" :class="{ ready: draft, sent }">
            <svg viewBox="0 0 16 16" width="16" height="16"><path d="M8 13V3.5M3.8 7.5L8 3.3l4.2 4.2" /></svg>
          </span>
        </div>
      </footer>
      </div>
      <button type="button" class="pause" :aria-label="userPaused ? 'Play the example conversation' : 'Pause the example conversation'" :aria-pressed="userPaused" @click="userPaused = !userPaused">
        <svg v-if="userPaused" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M4.5 2.8v10.4L13 8z" fill="currentColor" /></svg>
        <svg v-else viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M5 3v10M11 3v10" stroke="currentColor" stroke-width="3" /></svg>
      </button>

      <div class="cursor" :class="{ show: cursor.show, down: cursor.down }" :style="{ transform: `translate(${cursor.x}px, ${cursor.y}px)` }" aria-hidden="true">
        <svg viewBox="0 0 24 24" width="24" height="24"><path d="M4.5 3.2l14 8.1-6.1 1.5 3.4 6.4-2.6 1.4-3.4-6.4-4.6 4.3z" fill="#fff" stroke="#20241D" stroke-width="1.5" stroke-linejoin="round" /></svg>
      </div>
    </div>

    <div class="tabs" role="group" aria-label="Choose an example conversation">
      <button v-for="(scenario, index) in scenarios" :key="scenario.label" type="button" class="tab" :class="{ on: index === active }" :aria-pressed="index === active" @click="play(index)">
        <LemonFace :size="18" :color="scenario.color" :mood="index === active ? 'joy' : 'happy'" />
        {{ scenario.label }}
        <span class="tab-fill" :style="{ transform: `scaleX(${index === active ? progress : 0})` }" aria-hidden="true"></span>
      </button>
    </div>
  </div>
</template>

<style scoped>
/* Miniaturized from Lemon Bot web's styles.css and features/chat/chat.css. */
.chat-demo {
  --web-canvas: #F8F8F4; --web-sidebar: #F0F1E9; --web-bubble: #EBECE3; --web-raised: #FFF;
  --web-fill: rgb(43 49 42 / .06); --web-hover: rgb(43 49 42 / .045); --web-line: rgb(43 49 42 / .09);
  --web-ink: #2B312A; --web-muted: #6E766B; --web-faint: #949B8F; --web-accent: #3C6248; --web-on-accent: #FFF;
  --web-tint: #E6CC5A; --web-on-tint: #2E3420; --web-warning: #93691C; --web-shadow: 0 3px 10px rgb(0 0 0 / .10);
  position: relative; z-index: 2; width: 100%;
}
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; margin: 0; padding: 0; }
.window { position: relative; display: flex; flex-direction: column; height: 476px; border-radius: 13px; overflow: hidden; background: var(--web-canvas); border: 1px solid var(--web-line); box-shadow: 0 24px 60px -28px rgb(30 35 20 / .4), 0 4px 14px rgb(30 35 20 / .08); color: var(--web-ink); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 13px; line-height: 1.45; -webkit-font-smoothing: antialiased; }
.window svg:not(.lemon-face) { flex-shrink: 0; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.browser-chrome { flex: none; color: var(--web-muted); background: var(--web-sidebar); border-bottom: 1px solid var(--web-line); font-size: 9px; }
.browser-tabs { height: 25px; display: flex; align-items: center; gap: 10px; padding: 0 10px; }
.traffic { display: flex; gap: 4px; margin-right: 8px; }
.traffic i { width: 6px; height: 6px; border-radius: 50%; background: #FF5F57; }
.traffic i:nth-child(2) { background: #FEBC2E; } .traffic i:nth-child(3) { background: #28C840; }
.browser-tab { align-self: flex-end; display: flex; align-items: center; gap: 5px; width: 139px; height: 22px; padding: 0 9px; border-radius: 7px 7px 0 0; background: var(--web-canvas); color: var(--web-ink); }
.browser-tab > span { margin-left: auto; font-size: 12px; color: var(--web-muted); } .new-tab { font-size: 14px; }
.browser-toolbar { height: 28px; display: flex; align-items: center; gap: 10px; padding: 3px 11px 5px; background: var(--web-canvas); }
.browser-forward { opacity: .35; }
.address { display: flex; align-items: center; gap: 6px; flex: 1; height: 20px; border-radius: 999px; padding: 0 8px; background: var(--web-fill); }
.conversation { position: relative; flex: 1; min-height: 0; display: flex; flex-direction: column; }
.bar { position: absolute; z-index: 3; top: 0; left: 0; right: 0; height: 65px; display: flex; justify-content: center; pointer-events: none; background: linear-gradient(var(--web-canvas) 0%, color-mix(in srgb, var(--web-canvas) 94%, transparent) 50%, transparent 100%); }
.who { position: relative; margin-top: 10px; align-self: flex-start; display: inline-flex; align-items: center; gap: 7px; padding: 4px 11px 4px 5px; border-radius: 999px; background: var(--web-fill); }
.who b { font-size: 12px; font-weight: 600; letter-spacing: 0; }
.working-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--web-tint); animation: blip .9s ease-in-out infinite alternate; }
.header-icon { position: absolute; top: 8px; display: grid; place-items: center; width: 34px; height: 34px; border-radius: 50%; background: var(--web-raised); box-shadow: var(--web-shadow); }
.back { left: 10px; } .menu { right: 10px; color: var(--web-accent); } .menu svg { fill: currentColor; stroke: none; }
.allow-chip { position: absolute; top: 43px; left: 50%; transform: translateX(-50%); display: inline-flex; align-items: center; gap: 5px; padding: 3px 4px 3px 8px; border: 1px solid color-mix(in srgb, var(--web-tint) 35%, var(--web-line)); border-radius: 999px; background: var(--web-raised); box-shadow: var(--web-shadow); color: var(--web-muted); font-size: 9px; white-space: nowrap; pointer-events: auto; }
.allow-chip button { padding: 2px 6px; border-radius: 999px; background: var(--web-fill); color: var(--web-ink); font: inherit; }
.pause { position: absolute; right: 6px; top: 5px; display: grid; place-items: center; width: 19px; height: 17px; border-radius: 4px; color: var(--web-muted); background: var(--web-fill); }
.pause:hover { background: var(--web-line); color: var(--web-ink); }
.pause:focus-visible, .tab:focus-visible, .choices button:focus-visible, .verdict:focus-visible, .allow-chip button:focus-visible, summary:focus-visible { outline: 2px solid #E9D474; outline-offset: 2px; }
.log { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 12px; padding: 65px 16px 10px; overflow-y: auto; overscroll-behavior: contain; scrollbar-width: none; scroll-padding-top: 65px; }
.log::-webkit-scrollbar { display: none; } .log > :first-child { margin-top: auto; }
.row { display: flex; flex-shrink: 0; align-items: flex-start; min-width: 0; } .row-user { justify-content: flex-end; } .row-divider { justify-content: center; }
.divider { font-size: 10px; color: var(--web-faint); padding: 0; }
.bubble { max-width: 88%; padding: 8px 12px; border-radius: 16px; font-size: 13px; line-height: 1.45; overflow-wrap: anywhere; }
.bubble.me { background: var(--web-tint); color: var(--web-on-tint); } .bubble.them { background: var(--web-bubble); color: var(--web-ink); }
.bubble code { font-family: ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace; font-size: 11px; padding: 1px 4px; border-radius: 5px; background: color-mix(in srgb, var(--web-ink) 6%, transparent); }
.stream-caret { display: inline-block; width: 6px; height: 13px; margin-left: 2px; border-radius: 2px; background: currentColor; vertical-align: -2px; opacity: .5; animation: blip 1s infinite; }
.dots { display: inline-flex; gap: 4px; padding: 12px 14px; border-radius: 999px; color: var(--web-muted); }
.dots i, .activity-dots i { width: 5px; height: 5px; border-radius: 50%; background: currentColor; opacity: .45; animation: dot 2.4s ease-in-out infinite; }
.dots i:nth-child(2), .activity-dots i:nth-child(2) { animation-delay: .35s; } .dots i:nth-child(3), .activity-dots i:nth-child(3) { animation-delay: .7s; }
.crew { display: flex; flex-direction: column; min-width: 0; gap: 2px; }
.agent, .tool-summary { display: inline-flex; align-items: center; gap: 5px; padding: 2px 5px; color: var(--web-muted); font-size: 10px; font-weight: 500; min-width: 0; }
.agent-text { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; } .chevron { color: var(--web-faint); } .chevron.open { transform: rotate(90deg); }
.spinner { flex-shrink: 0; width: 9px; height: 9px; border-radius: 50%; border: 1.5px solid color-mix(in srgb, var(--web-muted) 35%, transparent); border-top-color: var(--web-muted); animation: spin .8s linear infinite; }
.approve { width: 88%; min-width: 0; display: flex; flex-direction: column; gap: 13px; padding: 12px; border-radius: 14px; background: var(--web-bubble); }
.approve-heading { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.approve h3 { margin: 0 0 6px; font: 650 13px/1.2 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; letter-spacing: -.02em; color: var(--web-ink); }
.badge { display: inline-flex; border-radius: 999px; padding: 2px 7px; font-size: 10px; background: var(--web-fill); color: var(--web-muted); }
.approve pre, .out { font-family: ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace; font-size: 10.5px; line-height: 1.55; color: var(--web-ink); background: color-mix(in srgb, var(--web-ink) 6%, transparent); border-radius: 10px; }
.approve pre { margin: 0; padding: 10px 12px; overflow-x: auto; white-space: pre; } .approve pre code { font: inherit; padding: 0; background: none; }
.approve-target { margin: 0 0 10px; font-size: 13px; line-height: 1.5; color: var(--web-muted); }
.approve-details { font-size: 13px; } .approve-details summary { width: fit-content; cursor: pointer; } .approve-details p { margin: 8px 0 0; font-size: 12px; }
.approve-details ul { margin: 8px 0; padding-left: 20px; } .approve-details dl { margin: 8px 0; } .approve-details dt { color: var(--web-muted); font-size: 10px; } .approve-details dd { margin: 0 0 8px; }
.gate-state { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; font-size: 10px; color: var(--web-muted); } .gate-state p { width: 100%; color: var(--web-ink); }
.choices { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.choices button { padding: 6px 12px; border: 1px solid var(--web-line); border-radius: 999px; background: var(--web-raised); color: var(--web-ink); font-size: 12px; line-height: 1.45; font-weight: 560; cursor: pointer; transition: background .14s, transform .12s; }
.choices button:hover { background: var(--web-hover); } .choices button:active, .choices button.pressed { transform: scale(.98); }
.choices .once { background: var(--web-accent); color: var(--web-on-accent); border-color: transparent; } .choices .once:hover { background: var(--web-accent); filter: brightness(1.08); }
.choices .deny { background: #A24C45; color: #FFF; border-color: transparent; } .choices .deny:hover { background: #A24C45; filter: brightness(1.08); }
.verdict { margin: 0 0 10px; font-size: 13px; line-height: 1.5; color: var(--web-ink); }
.tool-result { min-width: 0; max-width: 100%; } .out { margin: 3px 7px 5px 25px; padding: 7px 9px; background: var(--web-fill); font-size: 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
.row-remind { justify-content: center; } .remind { font-size: 10px; color: var(--web-muted); text-align: center; }
.dock { flex-shrink: 0; display: flex; flex-direction: column; gap: 7px; padding: 0 13px 12px; }
.activity { align-self: center; display: inline-flex; align-items: center; gap: 7px; max-width: 100%; padding: 4px 4px 4px 12px; border-radius: 999px; background: var(--web-fill); color: var(--web-ink); font-size: 10px; font-weight: 500; }
.activity.asking { background: color-mix(in srgb, var(--web-warning) 13%, transparent); } .hand { color: var(--web-warning); }
.activity-dots { display: inline-flex; gap: 3px; color: var(--web-muted); } .activity-dots i { width: 3px; height: 3px; }
.stop { display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 999px; background: var(--web-raised); box-shadow: var(--web-shadow); }
.composer { display: flex; align-items: flex-end; gap: 5px; padding: 6px; border: 1px solid var(--web-line); border-radius: 21px; background: var(--web-raised); box-shadow: 0 4px 12px rgb(0 0 0 / .08); }
.field { flex: 1; min-width: 0; min-height: 28px; padding: 4px 3px; font-size: 13px; line-height: 1.45; color: var(--web-ink); overflow-wrap: anywhere; } .placeholder { color: var(--web-muted); opacity: .8; }
.add, .mic, .send { flex: none; display: grid; place-items: center; width: 28px; height: 28px; border-radius: 50%; }
.add { background: var(--web-fill); } .mic { color: var(--web-muted); } .send { color: var(--web-on-tint); background: var(--web-tint); opacity: .4; transition: opacity .2s, transform .2s; }
.send svg { stroke-width: 2.6; } .send.ready { opacity: 1; } .send.sent { transform: scale(.8) translateY(-3px); }
.caret { display: inline-block; width: 1px; height: 1.1em; margin-left: 1px; vertical-align: -.18em; background: currentColor; animation: caret 1s steps(1) infinite; }
.cursor { position: absolute; left: 0; top: 0; z-index: 5; pointer-events: none; opacity: 0; transition: transform .9s cubic-bezier(.22, 1, .36, 1), opacity .3s; } .cursor.show { opacity: 1; }
.cursor svg { display: block; transform-origin: 4px 3px; transition: transform .12s; filter: drop-shadow(0 3px 4px rgb(0 0 0 / .25)); }
.cursor::before { content: ''; position: absolute; left: -11px; top: -12px; width: 30px; height: 30px; border-radius: 50%; background: var(--web-tint); opacity: 0; transform: scale(.3); }
.cursor.down svg { transform: scale(.8); } .cursor.down::before { animation: ripple .45s ease-out; }
.tabs { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; margin-top: 16px; }
.tab { position: relative; overflow: hidden; display: inline-flex; align-items: center; gap: 7px; padding: 7px 15px 7px 8px; border-radius: 999px; font-size: 13px; font-weight: 620; color: var(--vp-c-text-2); background: color-mix(in srgb, var(--vp-c-bg-soft) 80%, transparent); backdrop-filter: blur(6px); transition: background .2s, color .2s, transform .2s; }
.tab:hover { color: var(--vp-c-text-1); transform: translateY(-2px); } .tab.on { color: var(--vp-c-text-1); background: var(--web-canvas); box-shadow: inset 0 0 0 1px var(--vp-c-divider), 0 8px 18px -12px rgb(30 35 20 / .4); }
.tab-fill { position: absolute; left: 10px; right: 10px; bottom: 0; height: 2.5px; border-radius: 2px; background: var(--lemon-brand-deep); transform-origin: left; transition: transform .6s cubic-bezier(.22, 1, .36, 1); }
.paused .window *, .paused .window *::before, .paused .window *::after { animation-play-state: paused !important; }
.msg-enter-active { transition: opacity .3s, transform .36s cubic-bezier(.22, 1, .36, 1); } .msg-enter-from { opacity: 0; transform: translateY(8px); }
.swap-enter-active, .swap-leave-active { transition: opacity .25s, transform .25s; } .swap-enter-from, .swap-leave-to { opacity: 0; transform: translateY(8px); }
.flip-enter-active, .flip-leave-active { transition: opacity .18s, transform .18s; } .flip-enter-from { opacity: 0; transform: translateY(5px); } .flip-leave-to { opacity: 0; transform: translateY(-5px); }
.pop-enter-active { transition: opacity .3s; } .pop-enter-from { opacity: 0; }
@keyframes blip { 50% { opacity: .4; } }
@keyframes dot { 0%, 40%, 100% { opacity: .45; transform: translateY(0); } 20% { opacity: 1; transform: translateY(-3px); } }
@keyframes spin { to { transform: rotate(360deg); } } @keyframes caret { 50% { opacity: 0; } }
@keyframes ripple { from { opacity: .7; transform: scale(.3); } to { opacity: 0; transform: scale(1.3); } }
@media (max-width: 640px) { .window { height: 448px; } .log { padding-inline: 10px; } .dock { padding-inline: 7px; } }
@media (prefers-reduced-motion: reduce) { .chat-demo *, .chat-demo *::before, .chat-demo *::after { animation: none !important; transition: none !important; } }
</style>

<style>
.dark .chat-demo {
  --web-canvas: #121311; --web-sidebar: #181916; --web-bubble: #22241F; --web-raised: #252722;
  --web-fill: rgb(255 255 255 / .07); --web-hover: rgb(255 255 255 / .045); --web-line: rgb(255 255 255 / .08);
  --web-ink: #ECEDE6; --web-muted: #A0A598; --web-faint: #70756B; --web-accent: #A3C9A9; --web-on-accent: #14201A;
  --web-warning: #E6BA5E; --web-shadow: 0 0 #0000;
}
.dark .chat-demo .window { box-shadow: 0 24px 60px -28px rgb(0 0 0 / .7); }
.dark .chat-demo .composer { box-shadow: none; }
</style>
