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
    day: 'Today · 2:14 PM',
    steps: [
      { do: 'type', text: 'upload_test is flaky again. Can you take a look?' },
      { do: 'think', ms: 1000 },
      { do: 'say', text: 'On it. I’ll send a helper through the last CI log while I read the test.' },
      { do: 'agents', crew: [{ color: 'green', name: 'helper', task: 'reading ci.log', result: 'both failures touch /tmp/uploads', ms: 2600 }] },
      { do: 'say', text: 'Found it: two tests share `/tmp/uploads`. I gave each its own temp dir. Let me prove it:' },
      { do: 'approve', tool: 'Terminal', command: 'mix test test/upload_test.exs --repeat-until-failure 20' },
      { do: 'output', lines: ['····················', 'Finished in 1.9 seconds', '12 tests, 0 failures'] },
      { do: 'say', text: 'Twenty runs, all green. The fix is on `fix/upload-tmp-dir`. Open a PR?', mood: 'joy' },
    ],
    denied: 'No problem, I won’t run it. The fix is waiting on `fix/upload-tmp-dir` whenever you want to check it.',
  },
  {
    label: 'Remember',
    color: 'blue',
    day: 'Today · 8:02 AM',
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
    day: 'Today · 4:37 PM',
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
  if (phase.value === 'thinking') return 'thinking…'
  if (phase.value === 'asking') return 'waiting for your OK'
  if (phase.value === 'working' && working.value) return `${working.value} helper${working.value === 1 ? '' : 's'} working`
  if (phase.value === 'working') return 'running a tool'
  return 'online · studio-mac'
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
      <header class="bar">
        <LemonFace :size="36" leaf :mood="mood" />
        <div class="who">
          <b>Lemon</b>
          <span class="status" :class="phase" aria-hidden="true"><i></i>{{ status }}</span>
        </div>
        <Transition name="pop">
          <span v-if="allowance" class="allow-chip" aria-hidden="true">Terminal allowed · this chat</span>
        </Transition>
        <button type="button" class="pause" :aria-label="userPaused ? 'Play the example conversation' : 'Pause the example conversation'" :aria-pressed="userPaused" @click="userPaused = !userPaused">
          <svg v-if="userPaused" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4.5 2.8v10.4L13 8z" fill="currentColor" /></svg>
          <svg v-else viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><rect x="3.5" y="3" width="3" height="10" rx="1.2" fill="currentColor" /><rect x="9.5" y="3" width="3" height="10" rx="1.2" fill="currentColor" /></svg>
        </button>
      </header>

      <Transition name="swap" mode="out-in">
        <div ref="scroller" :key="active" class="log">
          <TransitionGroup name="msg">
            <div v-for="item in log" :key="item.id" class="row" :class="`row-${item.kind}`">
              <span v-if="item.kind === 'divider'" class="divider">{{ item.text }}</span>
              <div v-else-if="item.kind === 'user'" class="bubble me"><span class="sr-only">You: </span>{{ item.text }}</div>

              <template v-else-if="item.kind === 'bot' || item.kind === 'think'">
                <LemonFace class="av" :size="24" leaf />
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
                <div v-for="agent in item.crew" :key="agent.name" class="agent" :class="[`tone-${agent.color}`, { done: agent.done }]">
                  <LemonFace :size="26" :color="agent.color" :mood="agent.done ? 'joy' : 'happy'" />
                  <Transition name="flip" mode="out-in">
                    <span :key="agent.done" class="agent-text"><b>{{ agent.name }}</b> {{ agent.done ? agent.result : agent.task }}</span>
                  </Transition>
                  <span class="agent-state">
                    <svg v-if="agent.done" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" /></svg>
                    <span v-else class="spinner"></span>
                  </span>
                </div>
              </div>

              <div v-else-if="item.kind === 'approve'" class="approve">
                <p class="approve-title">
                  <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="11" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M4.5 6.5l2 1.6-2 1.6M8.5 10h3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
                  Run in {{ item.tool }}?
                </p>
                <pre><span>$</span> {{ item.command }}</pre>
                <Transition name="flip" mode="out-in">
                  <div v-if="!item.choice" class="choices">
                    <button type="button" class="once" :class="{ pressed: item.pressing === 'once' }" @click="choose(item, 'once', true)">Allow once</button>
                    <button type="button" class="chat" @click="choose(item, 'chat', true)">Allow {{ item.tool }} for this chat</button>
                    <button type="button" class="deny" @click="choose(item, 'deny', true)">Deny</button>
                  </div>
                  <p v-else class="verdict" :class="item.choice" tabindex="-1">
                    <template v-if="item.choice === 'deny'">✕ Denied</template>
                    <template v-else-if="item.choice === 'chat'">✓ {{ item.tool }} allowed for this chat</template>
                    <template v-else>✓ Allowed once</template>
                  </p>
                </Transition>
              </div>

              <pre v-else-if="item.kind === 'output'" class="out"><span class="dim">$ {{ item.command }}</span>
<template v-for="(line, index) in item.lines" :key="index"><span :class="{ ok: / 0 failures/.test(line), ticks: /^·+$/.test(line) }">{{ line }}</span>
</template></pre>

              <div v-else-if="item.kind === 'remind'" class="remind">
                <LemonFace :size="30" color="purple" mood="sleepy" />
                <span><small>Reminder · {{ item.when }}</small>{{ item.what }}</span>
              </div>
            </div>
          </TransitionGroup>
        </div>
      </Transition>

      <footer class="composer" aria-hidden="true">
        <div class="field">
          <span v-if="draft">{{ draft }}<i class="caret"></i></span>
          <span v-else class="placeholder">Message Lemon</span>
        </div>
        <span class="send" :class="{ ready: draft, sent }">
          <svg viewBox="0 0 16 16" width="16" height="16"><path d="M8 13V3.5M3.8 7.5L8 3.3l4.2 4.2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" /></svg>
        </span>
      </footer>

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
.chat-demo {
  --tone-yellow: #EDD56C; --tone-green: #A3CA98; --tone-blue: #A0C4EA; --tone-pink: #E3AEC3;
  --tone-purple: #BDB2E3; --tone-orange: #EBB487; --tone-red: #E6A79F;
  --demo-bg: var(--vp-c-bg-elv);
  position: relative; z-index: 2; width: 100%;
}
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; margin: 0; padding: 0; }
.tone-green { --tone: var(--tone-green); } .tone-blue { --tone: var(--tone-blue); } .tone-pink { --tone: var(--tone-pink); } .tone-purple { --tone: var(--tone-purple); }

.window { position: relative; display: flex; flex-direction: column; height: 476px; border-radius: 28px; overflow: hidden; background: var(--demo-bg); border: 1px solid var(--vp-c-divider); box-shadow: 0 40px 70px -40px rgb(30 35 20 / .5), 0 14px 30px -20px rgb(30 35 20 / .22); animation: window-in 1s .15s cubic-bezier(.22, 1, .36, 1) both; }

.bar { display: flex; align-items: center; gap: 11px; padding: 13px 14px 12px 16px; border-bottom: 1px solid var(--vp-c-divider); background: color-mix(in srgb, var(--vp-c-bg-alt) 55%, var(--demo-bg)); }
.who { display: flex; flex-direction: column; gap: 2px; flex: 1; min-width: 0; line-height: 1.2; }
.who b { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100; font-size: 17px; font-weight: 620; letter-spacing: -.01em; color: var(--vp-c-text-1); }
.status { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--vp-c-text-3); white-space: nowrap; }
.status i { width: 7px; height: 7px; border-radius: 50%; background: #7DB46C; transition: background .3s; }
.status.thinking i, .status.asking i { background: var(--lemon-brand-deep); animation: blip .9s ease-in-out infinite; }
.status.working i { background: #6E9EDB; animation: blip .7s ease-in-out infinite; }
.allow-chip { padding: 4px 10px; border-radius: 999px; font-size: 11px; font-weight: 650; white-space: nowrap; color: #3C6248; background: color-mix(in srgb, var(--tone-green) 35%, var(--demo-bg)); }
.pause { flex: none; display: grid; place-items: center; width: 32px; height: 32px; border-radius: 50%; color: var(--vp-c-text-2); background: var(--vp-c-default-soft); transition: background .2s, color .2s, transform .15s; }
.pause:hover { background: color-mix(in srgb, var(--lemon-brand) 45%, var(--vp-c-default-soft)); color: var(--vp-c-text-1); }
.pause:active { transform: scale(.92); }
.pause:focus-visible, .tab:focus-visible, .choices button:focus-visible, .verdict:focus-visible { outline: 3px solid var(--lemon-brand); outline-offset: 3px; }

.log { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 10px; padding: 18px 16px 10px; overflow: hidden; }
.log > :first-child { margin-top: auto; }
.row { display: flex; align-items: flex-end; gap: 8px; }
.row-user { justify-content: flex-end; }
.row-divider { justify-content: center; }
.divider { padding: 3px 11px; border-radius: 999px; font-size: 11px; font-weight: 600; letter-spacing: .04em; color: var(--vp-c-text-3); background: var(--vp-c-default-soft); }
.row-agents, .row-approve, .row-output, .row-remind { padding-left: 32px; }
.av { margin-bottom: 2px; }
.bubble { max-width: 84%; padding: 9px 13px; border-radius: 18px; font-size: 13.5px; line-height: 1.5; overflow-wrap: anywhere; }
.bubble.me { background: var(--lemon-brand); color: var(--lemon-ink); border-bottom-right-radius: 6px; transform-origin: right bottom; }
.bubble.them { background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); border-bottom-left-radius: 6px; transform-origin: left bottom; }
.bubble code { white-space: nowrap; font-family: var(--vp-font-family-mono); font-size: .86em; padding: .1em .38em; border-radius: 6px; background: color-mix(in srgb, var(--lemon-brand) 38%, transparent); }
.stream-caret { display: inline-block; width: 7px; height: 7px; margin-left: 4px; border-radius: 50%; background: var(--lemon-brand-deep); vertical-align: middle; animation: blip .6s ease-in-out infinite; }
.dots { display: inline-flex; gap: 5px; padding: 13px 15px; }
.dots i { width: 7px; height: 7px; border-radius: 50%; background: var(--vp-c-text-3); animation: dot 1.1s ease-in-out infinite; }
.dots i:nth-child(2) { animation-delay: .15s; }
.dots i:nth-child(3) { animation-delay: .3s; }

.crew { flex: 1; display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.agent { position: relative; display: flex; align-items: center; gap: 9px; padding: 6px 12px 6px 7px; border-radius: 15px; overflow: hidden; background: color-mix(in srgb, var(--tone) 22%, var(--demo-bg)); font-size: 12.5px; color: var(--vp-c-text-2); transition: background .4s; }
.agent::after { content: ''; position: absolute; left: 0; bottom: 0; width: 38%; height: 2.5px; border-radius: 2px; background: color-mix(in srgb, var(--tone) 80%, #2B312A); animation: scan 1.3s ease-in-out infinite; }
.agent.done { background: color-mix(in srgb, var(--tone) 34%, var(--demo-bg)); }
.agent.done::after { display: none; }
.agent:not(.done) :deep(.lemon-face) { animation: hop-sm .8s ease-in-out infinite; }
.agent-text { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.agent-text b { margin-right: 4px; font-weight: 680; color: var(--vp-c-text-1); }
.agent-state { display: grid; place-items: center; width: 18px; height: 18px; color: #3C6248; }
.spinner { width: 13px; height: 13px; border-radius: 50%; border: 2px solid color-mix(in srgb, var(--vp-c-text-1) 15%, transparent); border-top-color: var(--vp-c-text-2); animation: spin .8s linear infinite; }

.approve { flex: 1; min-width: 0; padding: 12px 12px 12px 14px; border-radius: 18px; background: color-mix(in srgb, var(--lemon-brand) 18%, var(--demo-bg)); box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--lemon-brand-deep) 55%, transparent); }
.approve-title { display: flex; align-items: center; gap: 7px; margin: 0; font-size: 12.5px; font-weight: 680; color: var(--vp-c-text-1); }
.approve pre, .out { margin: 0; font-family: var(--vp-font-family-mono); font-size: 11.5px; line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; color: #ECEDE6; background: var(--lemon-ink-panel); }
.approve pre { margin: 8px 0 10px; padding: 8px 11px; border-radius: 11px; }
.approve pre span { color: var(--lemon-brand); font-weight: 700; }
.choices { display: flex; flex-wrap: wrap; gap: 6px; }
.choices button { padding: 6px 12px; border-radius: 999px; font-size: 12px; font-weight: 650; cursor: pointer; transition: transform .14s cubic-bezier(.34, 1.56, .64, 1), background .2s, box-shadow .2s; }
.choices button:hover { transform: translateY(-1px); }
.choices button:active, .choices button.pressed { transform: scale(.92); }
.choices .once { background: var(--lemon-brand); color: var(--lemon-ink); box-shadow: 0 2px 0 var(--lemon-brand-deep); }
.choices .chat { background: var(--demo-bg); color: var(--vp-c-text-1); box-shadow: inset 0 0 0 1px var(--vp-c-border); }
.choices .deny { color: var(--vp-c-text-2); }
.choices .deny:hover { color: var(--vp-c-danger-1); }
.verdict { margin: 0; font-size: 12.5px; font-weight: 680; color: #3C6248; }
.verdict.deny { color: var(--vp-c-danger-1); }

.out { flex: 1; min-width: 0; padding: 10px 13px; border-radius: 15px; }
.out .dim { color: #858A7E; }
.out .ticks { color: #8CCB98; letter-spacing: .08em; }
.out .ok { color: #8CCB98; font-weight: 650; }

.remind { flex: 1; display: flex; align-items: center; gap: 10px; padding: 8px 14px 8px 8px; border-radius: 16px; background: color-mix(in srgb, var(--tone-purple) 28%, var(--demo-bg)); font-size: 13px; color: var(--vp-c-text-1); }
.remind small { display: block; font-size: 11px; font-weight: 650; letter-spacing: .04em; text-transform: uppercase; color: var(--vp-c-text-2); }

.composer { display: flex; align-items: center; gap: 10px; padding: 10px 12px 12px 14px; border-top: 1px solid var(--vp-c-divider); }
.field { flex: 1; min-width: 0; min-height: 40px; display: flex; align-items: center; padding: 9px 16px; border-radius: 20px; background: var(--vp-c-bg-soft); font-size: 13.5px; line-height: 1.45; color: var(--vp-c-text-1); }
.placeholder { color: var(--vp-c-text-3); }
.caret { display: inline-block; width: 1.5px; height: 1.1em; margin-left: 1px; vertical-align: -.18em; background: currentColor; animation: caret 1s steps(1) infinite; }
.send { flex: none; display: grid; place-items: center; width: 40px; height: 40px; border-radius: 50%; color: var(--vp-c-text-3); background: var(--vp-c-default-soft); transition: background .2s, color .2s, transform .25s cubic-bezier(.34, 1.56, .64, 1); }
.send.ready { background: var(--lemon-brand); color: var(--lemon-ink); }
.send.sent { transform: scale(.8) translateY(-3px); }

.cursor { position: absolute; left: 0; top: 0; z-index: 5; pointer-events: none; opacity: 0; transition: transform .9s cubic-bezier(.22, 1, .36, 1), opacity .3s; }
.cursor.show { opacity: 1; }
.cursor svg { display: block; transform-origin: 4px 3px; transition: transform .12s; filter: drop-shadow(0 3px 4px rgb(0 0 0 / .25)); }
.cursor::before { content: ''; position: absolute; left: -11px; top: -12px; width: 30px; height: 30px; border-radius: 50%; background: var(--lemon-brand); opacity: 0; transform: scale(.3); }
.cursor.down svg { transform: scale(.8); }
.cursor.down::before { animation: ripple .45s ease-out; }

.tabs { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; margin-top: 16px; }
.tab { position: relative; overflow: hidden; display: inline-flex; align-items: center; gap: 7px; padding: 7px 15px 7px 8px; border-radius: 999px; font-size: 13px; font-weight: 620; color: var(--vp-c-text-2); background: color-mix(in srgb, var(--vp-c-bg-soft) 80%, transparent); backdrop-filter: blur(6px); transition: background .2s, color .2s, transform .2s cubic-bezier(.34, 1.56, .64, 1); }
.tab:hover { color: var(--vp-c-text-1); transform: translateY(-2px); }
.tab.on { color: var(--vp-c-text-1); background: var(--demo-bg); box-shadow: inset 0 0 0 1px var(--vp-c-divider), 0 8px 18px -12px rgb(30 35 20 / .4); }
.tab-fill { position: absolute; left: 10px; right: 10px; bottom: 0; height: 2.5px; border-radius: 2px; background: var(--lemon-brand-deep); transform-origin: left; transition: transform .6s cubic-bezier(.22, 1, .36, 1); }

.paused .window *, .paused .window *::before, .paused .window *::after { animation-play-state: paused !important; }

.msg-enter-active { transition: opacity .3s, transform .45s cubic-bezier(.34, 1.4, .64, 1); }
.msg-enter-from { opacity: 0; transform: translateY(12px) scale(.96); }
.row-user.msg-enter-from { transform: translate(8px, 12px) scale(.94); }
.swap-enter-active, .swap-leave-active { transition: opacity .25s, transform .25s; }
.swap-enter-from, .swap-leave-to { opacity: 0; transform: translateY(8px); }
.flip-enter-active, .flip-leave-active { transition: opacity .18s, transform .18s; }
.flip-enter-from { opacity: 0; transform: translateY(5px); }
.flip-leave-to { opacity: 0; transform: translateY(-5px); }
.pop-enter-active { transition: opacity .3s, transform .4s cubic-bezier(.34, 1.56, .64, 1); }
.pop-enter-from { opacity: 0; transform: scale(.6); }

@keyframes window-in { from { opacity: 0; transform: translateY(26px) scale(.97); } to { opacity: 1; transform: none; } }
@keyframes blip { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: .45; transform: scale(.75); } }
@keyframes dot { 0%, 60%, 100% { transform: translateY(0); opacity: .45; } 30% { transform: translateY(-5px); opacity: 1; } }
@keyframes scan { from { transform: translateX(-100%); } to { transform: translateX(270%); } }
@keyframes hop-sm { 0%, 100% { transform: translateY(0) rotate(0); } 50% { transform: translateY(-2.5px) rotate(-5deg); } }
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes caret { 50% { opacity: 0; } }
@keyframes ripple { from { opacity: .7; transform: scale(.3); } to { opacity: 0; transform: scale(1.3); } }

@media (max-width: 640px) {
  .window { height: 448px; border-radius: 24px; }
  .row-agents, .row-approve, .row-output, .row-remind { padding-left: 0; }
  .bubble { max-width: 90%; font-size: 13px; }
  .allow-chip { display: none; }
}
@media (prefers-reduced-motion: reduce) {
  .chat-demo *, .chat-demo *::before, .chat-demo *::after { animation: none !important; transition: none !important; }
}
</style>

<style>
.dark .chat-demo { --demo-bg: #191A17; }
.dark .chat-demo .window { border-color: rgb(255 255 255 / .08); box-shadow: 0 40px 80px -30px rgb(0 0 0 / .8); }
.dark .chat-demo .bar { background: #1E201B; }
.dark .chat-demo .agent { background: color-mix(in srgb, var(--tone) 13%, #191A17); }
.dark .chat-demo .agent.done { background: color-mix(in srgb, var(--tone) 20%, #191A17); }
.dark .chat-demo .agent::after { background: var(--tone); }
.dark .chat-demo .agent-state, .dark .chat-demo .verdict { color: #A3C9A9; }
.dark .chat-demo .verdict.deny { color: var(--vp-c-danger-1); }
.dark .chat-demo .approve { background: color-mix(in srgb, var(--lemon-brand) 8%, #191A17); box-shadow: inset 0 0 0 1.5px rgb(233 212 116 / .35); }
.dark .chat-demo .approve pre, .dark .chat-demo .out { background: #111210; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .06); }
.dark .chat-demo .bubble code { background: rgb(233 212 116 / .14); color: #F2E3A0; }
.dark .chat-demo .remind { background: color-mix(in srgb, var(--tone-purple) 14%, #191A17); }
.dark .chat-demo .allow-chip { color: #A3C9A9; background: rgb(163 202 152 / .14); }
.dark .chat-demo .tab.on { box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); }
</style>
