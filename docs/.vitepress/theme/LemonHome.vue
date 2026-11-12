<script setup>
import { onBeforeUnmount, ref } from 'vue'
import { withBase } from 'vitepress'
import LemonChatDemo from './LemonChatDemo.vue'
import IosAppMock from './IosAppMock.vue'
import LemonFace from './LemonFace.vue'
import LemonSlice from './LemonSlice.vue'
import MacAppMock from './MacAppMock.vue'
import TuiMock from './TuiMock.vue'

const installer = 'curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh'
const installs = [
  { label: 'Lemon Bot · browser setup', command: `${installer} -s -- --profile bot` },
  { label: 'Lemon · terminal setup', command: installer },
]
const copied = ref('')
let copiedTimer
async function copyInstall(command) {
  try {
    await navigator.clipboard.writeText(command)
    copied.value = command
    clearTimeout(copiedTimer)
    copiedTimer = setTimeout(() => { copied.value = '' }, 1800)
  } catch {
    copied.value = ''
  }
}

const ticker = ['Durable sessions', 'Native subagents', 'Memory & recall', 'Reusable skills', 'Your models, your keys', 'Terminal', 'Browser', 'Telegram & Discord', 'MCP tools', 'Supervised on the BEAM', 'LemonSim arenas']
const tickerColors = ['yellow', 'green', 'blue', 'pink', 'purple', 'orange', 'red']

const features = [
  { color: 'blue', mood: 'wink', title: 'Context that sticks around.', text: 'Come back to durable sessions, search useful memory, and turn repeatable workflows into skills. Your project conventions stay close to the work.', link: '/user-guide/memory', label: 'Explore memory' },
  { color: 'green', mood: 'joy', crew: true, title: 'More than one pair of hands.', text: 'Delegate to native subagents in the same runtime, or send work to a named execution node — all coordinated from one conversation.', link: '/architecture/overview', label: 'Meet the runtime' },
  { color: 'purple', mood: 'surprised', title: 'Bring any brain.', text: 'Configure providers and models through one platform. Files and runtime state stay on your machine; the model is your call.', link: '/user-guide/setup', label: 'Set up a provider' },
  { color: 'orange', mood: 'derp', title: 'Built to be poked at.', text: 'Inspect runs, validate configuration, diagnose setup, and back up durable state. Real tools for the work after “hello world.”', link: '/support', label: 'See the support tools' },
]

const workers = [
  { color: 'green', label: 'session' },
  { color: 'blue', label: 'tool run' },
  { color: 'pink', label: 'subagent', crashes: true },
  { color: 'purple', label: 'channel' },
]

const paths = [
  { color: 'yellow', mood: 'happy', leaf: true, tag: 'Use Lemon Bot', title: 'Your first useful Bot.', text: 'Install, connect a model, and create a Bot in your browser. Review commands before they run.', link: '/getting-started/lemon-bot', label: 'Set up Lemon Bot' },
  { color: 'green', mood: 'joy', tag: 'Build with Lemon', title: 'Make it your own.', text: 'Explore the agent stack, write reusable skills, and build on the control plane.', link: '/getting-started/build-your-first-agent', label: 'Build your first agent' },
  { color: 'red', mood: 'derp', tag: 'Explore LemonSim', title: 'Put agents to the test.', text: 'Run deterministic, event-sourced simulation worlds with replay verification.', link: '/benchmarks/quickstart', label: 'Enter the arena' },
]

const choir = ['green', 'blue', 'pink', 'yellow', 'purple', 'orange', 'red']
const choirMoods = ['happy', 'joy', 'wink', 'happy', 'surprised', 'joy', 'derp']

// Hero mascot: mirrors the demo Bot's mood, and squeezes when poked.
const demoMood = ref('happy')
const squeezeMood = ref('')
const squish = ref(null)
const drops = ref([])
const shouts = ref([])
const SHOUTS = ['zing!', 'zest!', 'pucker!', 'juicy!', 'so sour!', 'squeeze!']
let squeezes = 0
let sprayId = 0
const timers = new Set()
function later(fn, ms) {
  const timer = setTimeout(() => { timers.delete(timer); fn() }, ms)
  timers.add(timer)
}
function squeeze() {
  squeezes += 1
  const count = squeezes
  squeezeMood.value = count >= 5 ? 'derp' : 'joy'
  later(() => { if (squeezes === count) { squeezes = 0; squeezeMood.value = '' } }, 1600)
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
  squish.value?.animate(
    [{ transform: 'none' }, { transform: 'scale(1.16, .8)', offset: .28 }, { transform: 'scale(.93, 1.09)', offset: .6 }, { transform: 'none' }],
    { duration: 560, easing: 'cubic-bezier(.34, 1.56, .64, 1)' },
  )
  const burst = Array.from({ length: 11 }, (_, index) => {
    const angle = Math.PI * (1.06 + 0.88 * (index / 10)) + (Math.random() - 0.5) * 0.3
    const distance = 80 + Math.random() * 80
    return { id: ++sprayId, dx: `${Math.cos(angle) * distance}px`, dy: `${Math.sin(angle) * distance}px`, size: `${7 + Math.random() * 8}px`, turn: `${(angle * 180) / Math.PI + 225}deg` }
  })
  const shout = { id: ++sprayId, text: count >= 5 ? 'okay, okay!' : SHOUTS[(count - 1) % SHOUTS.length], x: `${Math.round((Math.random() - 0.5) * 80)}px` }
  drops.value.push(...burst)
  shouts.value.push(shout)
  later(() => {
    drops.value = drops.value.filter((drop) => !burst.includes(drop))
    shouts.value = shouts.value.filter((item) => item !== shout)
  }, 1200)
}
onBeforeUnmount(() => timers.forEach(clearTimeout))

// Scroll reveal: below-the-fold blocks rise in once. Content already on screen
// at hydration (or with reduced motion) is left alone, so nothing flickers.
const vReveal = {
  mounted(el) {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches || el.getBoundingClientRect().top < innerHeight * 0.9) return
    el.classList.add('reveal-pending')
    el._reveal = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) return
      el.classList.replace('reveal-pending', 'is-revealed')
      el._reveal.disconnect()
    }, { rootMargin: '0px 0px -12% 0px' })
    el._reveal.observe(el)
  },
  unmounted(el) { el._reveal?.disconnect() },
}
</script>

<template>
  <div class="lemon-home">
    <section class="hero" aria-labelledby="hero-title">
      <div class="hero-copy">
        <a class="pill" :href="withBase('/compare')">
          <LemonFace :size="18" mood="joy" />
          Open source · MIT · pre-1.0
          <span aria-hidden="true">→</span>
        </a>
        <h1 id="hero-title">
          <span class="line">Your agents.</span>
          <span class="line">Your machine.</span>
          <span class="line move"><em>Your move.</em></span>
        </h1>
        <p class="lede">Meet Lemon — a local-first AI assistant that brings your models, tools, and conversations together, and keeps useful context close.</p>

        <template v-for="install in installs" :key="install.command">
          <p class="footnote install-label">{{ install.label }}</p>
          <div class="install">
            <span class="prompt" aria-hidden="true">$</span>
            <code>{{ install.command }}</code>
            <button type="button" class="copy" :class="{ done: copied === install.command }" :aria-label="`Copy ${install.label} command`" @click="copyInstall(install.command)">
              <LemonFace :size="18" :mood="copied === install.command ? 'joy' : 'happy'" />
              <span>{{ copied === install.command ? 'Copied!' : 'Copy' }}</span>
            </button>
            <span class="sr-only" aria-live="polite">{{ copied === install.command ? `${install.label} command copied` : '' }}</span>
          </div>
        </template>

        <div class="actions">
          <a class="btn primary" :href="withBase('/getting-started/lemon-bot')">Set up Lemon Bot <span aria-hidden="true">→</span></a>
          <a class="btn ghost" :href="withBase('/getting-started/quickstart')">Terminal quickstart <span aria-hidden="true">→</span></a>
        </div>
        <p class="footnote">Self-hosted · macOS &amp; Linux · Built on Elixir / OTP</p>
      </div>

      <div class="stage">
        <div class="slice-wrap" aria-hidden="true">
          <LemonSlice />
          <div class="orbit"></div>
        </div>
        <p class="aside-note" aria-hidden="true">
          a real-ish Lemon Bot chat.<br>go on, press <b>Allow</b> yourself
          <svg viewBox="0 0 60 52" width="54" height="46"><path d="M6 4c18 2 34 12 40 38" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" /><path d="M37 36l9 8 4-11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" /></svg>
        </p>
        <button type="button" class="mascot" aria-label="Squeeze the lemon" @click="squeeze">
          <span class="mascot-hint" aria-hidden="true">squeeze me</span>
          <span ref="squish" class="squish" :class="{ cheer: demoMood === 'joy' }"><LemonFace :size="200" leaf blush track :mood="squeezeMood || demoMood" /></span>
          <span v-for="drop in drops" :key="drop.id" class="drop" :style="{ '--dx': drop.dx, '--dy': drop.dy, '--s': drop.size, '--r': drop.turn }" aria-hidden="true"></span>
          <span v-for="shout in shouts" :key="shout.id" class="shout" :style="{ '--x': shout.x }" aria-hidden="true">{{ shout.text }}</span>
        </button>
        <LemonChatDemo @mood="demoMood = $event" />
      </div>
    </section>

    <div class="ticker" aria-label="Lemon capabilities">
      <div class="ticker-track">
        <template v-for="copy in 2" :key="copy">
          <span v-for="(item, index) in ticker" :key="`${copy}-${item}`" class="ticker-item" :aria-hidden="copy === 2 ? 'true' : undefined">
            <LemonFace :size="22" :color="tickerColors[index % tickerColors.length]" :mood="index % 3 === 1 ? 'joy' : 'happy'" />
            {{ item }}
          </span>
        </template>
      </div>
    </div>

    <section class="section" aria-labelledby="features-title">
      <header v-reveal class="section-head reveal-stagger">
        <p class="kicker">From a prompt to a practice</p>
        <h2 id="features-title">Good work deserves<br>a place to <em>continue</em>.</h2>
        <p>One runtime for everything an assistant needs beyond its next answer.</p>
      </header>
      <div v-reveal class="features reveal-stagger">
        <a v-for="(feature, index) in features" :key="feature.title" class="feature" :class="`tone-${feature.color}`" :style="{ '--i': index }" :href="withBase(feature.link)">
          <div class="feature-art" aria-hidden="true">
            <template v-if="feature.crew">
              <LemonFace :size="64" :color="feature.color" :mood="feature.mood" track />
              <LemonFace class="crew-b" :size="40" color="blue" mood="happy" />
              <LemonFace class="crew-c" :size="32" color="pink" mood="wink" />
            </template>
            <LemonFace v-else :size="68" :color="feature.color" :mood="feature.mood" track />
          </div>
          <h3>{{ feature.title }}</h3>
          <p>{{ feature.text }}</p>
          <span class="feature-link">{{ feature.label }} <span aria-hidden="true">→</span></span>
        </a>
      </div>
    </section>

    <section v-reveal class="beam reveal-solo" aria-labelledby="beam-title">
      <div class="beam-copy">
        <p class="kicker">Solid foundations</p>
        <h2 id="beam-title">Agents are a<br><em>concurrency</em> problem.</h2>
        <p>Tools run. Messages arrive. Sessions wait. Work gets delegated. Lemon uses the BEAM’s lightweight processes and supervision to give all that activity a structure you can reason about — and when something crashes, it gets restarted while everything else keeps working.</p>
        <a class="text-link" :href="withBase('/why-beam-for-agents')">Why we built on the BEAM <span aria-hidden="true">→</span></a>
      </div>
      <div class="tree" role="img" aria-label="A supervisor lemon watches four worker lemons. One worker crashes and is restarted while the others keep running.">
        <div class="tree-root">
          <LemonFace :size="78" leaf />
          <span>supervisor</span>
        </div>
        <div class="tree-branches">
          <div v-for="(worker, index) in workers" :key="worker.label" class="worker" :class="{ crashes: worker.crashes }">
            <i class="pulse" :style="{ '--i': index }" aria-hidden="true"></i>
            <div class="worker-face">
              <LemonFace class="alive" :size="54" :color="worker.color" mood="happy" />
              <LemonFace v-if="worker.crashes" class="dead" :size="54" color="#C9CBBF" mood="crashed" />
            </div>
            <span>{{ worker.label }}</span>
            <em v-if="worker.crashes" class="restart">restarted ✓</em>
          </div>
        </div>
        <p class="tree-caption">let it crash · restart · carry on</p>
      </div>
    </section>

    <section class="section" aria-labelledby="doors-title">
      <header v-reveal class="section-head reveal-stagger">
        <p class="kicker">Wherever you work</p>
        <h2 id="doors-title">One lemon.<br><em>Every door.</em></h2>
        <p>The same Bots, sessions, memory and tools in the terminal, the Mac and iPhone apps, the browser app up top, or the Telegram and Discord chats you already use.</p>
      </header>
      <div v-reveal class="doors reveal-stagger">
        <a class="door" style="--i: 0" :href="withBase('/user-guide/cli')">
          <div class="mock"><TuiMock /></div>
          <h3>Terminal</h3>
          <p>A fast TUI for long coding sessions, with slash commands and resumable history.</p>
        </a>
        <a class="door" style="--i: 1" :href="withBase('/getting-started/lemon-bot#a-mac-app')">
          <div class="mock"><MacAppMock /></div>
          <h3>Mac</h3>
          <p>The native Lemon Bot app, with every Bot, chat and approval a click away.</p>
        </a>
        <a class="door" style="--i: 2" :href="withBase('/getting-started/lemon-bot#connect-an-iphone')">
          <div class="mock"><IosAppMock /></div>
          <h3>iPhone</h3>
          <p>Check in on a Bot, read its answers and approve a command from your pocket.</p>
        </a>
      </div>
    </section>

    <section class="section paths-section" aria-labelledby="paths-title">
      <header v-reveal class="section-head reveal-stagger">
        <p class="kicker">Pick your starting point</p>
        <h2 id="paths-title">Make something <em>happen</em>.</h2>
      </header>
      <div v-reveal class="paths reveal-stagger">
        <a v-for="(path, index) in paths" :key="path.tag" :href="withBase(path.link)" class="path" :class="`tone-${path.color}`" :style="{ '--i': index }">
          <LemonFace class="path-face" :size="56" :color="path.color" :mood="path.mood" :leaf="path.leaf" />
          <span class="kicker">{{ path.tag }}</span>
          <h3>{{ path.title }}</h3>
          <p>{{ path.text }}</p>
          <span class="feature-link">{{ path.label }} <span aria-hidden="true">→</span></span>
        </a>
      </div>
    </section>

    <section v-reveal class="closing reveal-solo" aria-labelledby="closing-title">
      <div class="choir" aria-hidden="true">
        <LemonFace v-for="(color, index) in choir" :key="color" :size="index === 3 ? 92 : 58" :color="color" :mood="choirMoods[index]" :leaf="index === 3" :blush="index === 3" track :style="{ '--i': index }" />
      </div>
      <h2 id="closing-title">Early days.<br><em>Real building blocks.</em></h2>
      <p>Lemon is pre-1.0 and evolving fast. Start with the supported install path, explore the documented capabilities, and help shape what comes next.</p>
      <div class="actions center">
        <a class="btn primary" :href="withBase('/install')">Install Lemon <span aria-hidden="true">→</span></a>
        <a class="btn ghost" :href="withBase('/compare')">Capabilities &amp; boundaries</a>
      </div>
    </section>
  </div>
</template>

<style scoped>
.lemon-home {
  --tone-yellow: #EDD56C; --tone-green: #A3CA98; --tone-blue: #A0C4EA; --tone-pink: #E3AEC3;
  --tone-purple: #BDB2E3; --tone-orange: #EBB487; --tone-red: #E6A79F;
  max-width: 1240px; margin: 0 auto; padding: 0 40px;
}
.lemon-home a { text-decoration: none; color: inherit; }
.lemon-home a:focus-visible, .lemon-home button:focus-visible { outline: 3px solid var(--lemon-brand); outline-offset: 4px; border-radius: 14px; }
.lemon-home em { font-style: italic; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

.kicker { font-size: 12px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; color: var(--vp-c-text-2); margin: 0 0 14px; }

/* Hero */
.hero { display: grid; grid-template-columns: minmax(0, 1.05fr) minmax(0, 1fr); gap: 48px; align-items: center; padding: 72px 0 64px; }
.pill { display: inline-flex; align-items: center; gap: 9px; padding: 6px 14px 6px 8px; border-radius: 999px; background: var(--vp-c-bg-soft); color: var(--vp-c-text-2) !important; font-size: 13px; font-weight: 550; transition: background .2s, transform .2s; }
.pill:hover { background: color-mix(in srgb, var(--lemon-brand) 45%, var(--vp-c-bg-soft)); color: var(--lemon-ink) !important; transform: translateY(-1px); }
.hero h1 { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 0; font-weight: 560; font-size: clamp(52px, 6.6vw, 92px); line-height: .98; letter-spacing: -.035em; margin: 26px 0 24px; color: var(--vp-c-text-1); }
.hero h1 .line { display: block; animation: rise .8s cubic-bezier(.22, 1, .36, 1) both; }
.hero h1 .line:nth-child(2) { animation-delay: .08s; }
.hero h1 .line:nth-child(3) { animation-delay: .16s; }
.hero h1 .move em { font-variation-settings: 'SOFT' 100, 'WONK' 1; font-weight: 480; position: relative; z-index: 0; padding-right: .06em; }
.hero h1 .move em::after { content: ''; position: absolute; z-index: -1; left: -.04em; right: -.02em; bottom: .06em; height: .34em; border-radius: 999px; background: var(--lemon-brand); transform: rotate(-1.6deg) scaleX(0); transform-origin: left; animation: swipe .7s .55s cubic-bezier(.22, 1, .36, 1) forwards; }
.lede { font-size: 19px; line-height: 1.6; color: var(--vp-c-text-2); max-width: 500px; margin: 0; animation: rise .8s .24s cubic-bezier(.22, 1, .36, 1) both; }

.install { display: flex; align-items: flex-start; gap: 10px; margin-top: 30px; max-width: 540px; padding: 7px 7px 7px 16px; border-radius: 16px; background: var(--lemon-ink-panel); color: #ECEDE6; box-shadow: 0 1px 0 rgb(255 255 255 / .06) inset, 0 18px 40px -24px rgb(20 26 16 / .6); animation: rise .8s .32s cubic-bezier(.22, 1, .36, 1) both; }
.install .prompt { padding-top: 8px; font-size: 13px; line-height: 1.55; color: var(--lemon-brand); font-family: var(--vp-font-family-mono); font-weight: 700; }
/* Wrap rather than clip: both commands share a long prefix, so a clipped line hides the flags that tell them apart. */
.install code { flex: 1; min-width: 0; align-self: center; white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--vp-font-family-mono); font-size: 13px; line-height: 1.55; color: #ECEDE6; background: none; padding: 6px 0; }
.footnote.install-label { margin-top: 26px; font-weight: 600; color: var(--vp-c-text-2); animation-delay: .32s; }
.install-label + .install { margin-top: 8px; }
.copy { display: inline-flex; align-items: center; gap: 6px; flex: none; padding: 8px 12px 8px 9px; border-radius: 11px; background: rgb(255 255 255 / .08); color: #ECEDE6; font-size: 13px; font-weight: 600; transition: background .2s, transform .15s; }
.copy:hover { background: rgb(255 255 255 / .16); }
.copy:active { transform: scale(.96); }
.copy.done { background: var(--lemon-brand); color: var(--lemon-ink); }

.actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 22px; animation: rise .8s .4s cubic-bezier(.22, 1, .36, 1) both; }
.actions.center { justify-content: center; }
.btn { display: inline-flex; align-items: center; gap: 12px; padding: 13px 22px; border-radius: 999px; font-size: 15px; font-weight: 650; transition: transform .18s cubic-bezier(.22, 1, .36, 1), box-shadow .18s, background .18s; }
.btn.primary { background: var(--lemon-brand); color: var(--lemon-ink) !important; box-shadow: 0 3px 0 var(--lemon-brand-deep); }
.btn.primary:hover { transform: translateY(-2px); box-shadow: 0 5px 0 var(--lemon-brand-deep); }
.btn.primary:active { transform: translateY(1px); box-shadow: 0 1px 0 var(--lemon-brand-deep); }
.btn.ghost { background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.btn.ghost:hover { background: var(--vp-c-default-soft); transform: translateY(-2px); }
.footnote { margin: 18px 0 0; font-size: 13px; color: var(--vp-c-text-3); animation: rise .8s .46s cubic-bezier(.22, 1, .36, 1) both; }

.stage { position: relative; padding-top: 132px; }
.slice-wrap { position: absolute; z-index: 0; top: -30px; right: -76px; width: 440px; height: 440px; pointer-events: none; animation: slice-in 1.4s .05s cubic-bezier(.22, 1, .36, 1) both; }
.slice-wrap::before { content: ''; position: absolute; inset: -16%; border-radius: 50%; background: radial-gradient(circle, color-mix(in srgb, var(--lemon-brand) 50%, transparent), transparent 64%); filter: blur(12px); animation: breathe 7s ease-in-out infinite; }
.slice-wrap :deep(.lemon-slice) { position: relative; opacity: .92; animation: spin 150s linear infinite; }
.orbit { position: absolute; inset: -30px; border-radius: 50%; border: 1.5px dashed color-mix(in srgb, var(--vp-c-text-1) 16%, transparent); animation: spin 90s linear infinite reverse; }
.aside-note { position: absolute; z-index: 1; top: 16px; left: 6px; max-width: 210px; margin: 0; font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 1; font-style: italic; font-size: 16px; line-height: 1.3; color: var(--vp-c-text-2); rotate: -3deg; animation: float-in .7s 2.6s cubic-bezier(.34, 1.56, .64, 1) both; }
.aside-note b { font-weight: 650; color: var(--vp-c-text-1); }
.aside-note svg { display: block; margin: 2px 0 0 40px; color: var(--lemon-brand-deep); }
.mascot { position: absolute; z-index: 1; top: 0; right: 48px; padding: 0; border: 0; border-radius: 50%; background: none; cursor: pointer; -webkit-tap-highlight-color: transparent; animation: peek 1.1s .45s cubic-bezier(.34, 1.4, .64, 1) both; }
.squish { display: block; transform-origin: 50% 75%; }
.squish.cheer { animation: cheer .9s cubic-bezier(.34, 1.56, .64, 1); }
.mascot :deep(.lemon-face) { animation: bob 4.8s ease-in-out infinite; filter: drop-shadow(0 18px 24px rgb(80 70 10 / .18)); transition: rotate .45s cubic-bezier(.34, 1.56, .64, 1); }
.mascot:hover :deep(.lemon-face) { rotate: -7deg; }
.mascot-hint { position: absolute; z-index: 2; top: 26px; left: -74px; padding: 4px 11px; border-radius: 999px 999px 4px 999px; background: var(--vp-c-bg-elv); color: var(--vp-c-text-2); font-size: 12px; font-weight: 600; white-space: nowrap; box-shadow: 0 6px 16px -10px rgb(30 35 20 / .5); opacity: 0; transform: translateY(6px) scale(.9); transition: opacity .2s, transform .25s cubic-bezier(.34, 1.56, .64, 1); pointer-events: none; }
.mascot:hover .mascot-hint, .mascot:focus-visible .mascot-hint { opacity: 1; transform: none; }
.drop { position: absolute; z-index: 3; left: 50%; top: 40%; width: var(--s); height: var(--s); margin: calc(var(--s) / -2); border-radius: 50% 0 50% 50%; background: radial-gradient(circle at 35% 35%, #FFF7C9, #EDD56C 55%, #D6B841); pointer-events: none; animation: juice 1s cubic-bezier(.2, .7, .4, 1) forwards; }
.shout { position: absolute; z-index: 3; left: 50%; top: -18px; translate: calc(-50% + var(--x)) 0; font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 1; font-style: italic; font-weight: 650; font-size: 25px; color: var(--vp-c-text-1); white-space: nowrap; pointer-events: none; animation: shout 1.1s cubic-bezier(.22, 1, .36, 1) forwards; }

/* Ticker */
.ticker { position: relative; overflow: hidden; margin: 0 calc(50% - 50vw); padding: 18px 0; border-block: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-alt); }
.ticker-track { display: flex; width: max-content; animation: marquee 48s linear infinite; }
.ticker:hover .ticker-track { animation-play-state: paused; }
.ticker-item { display: inline-flex; align-items: center; gap: 10px; padding: 0 26px; font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100; font-size: 21px; font-weight: 500; letter-spacing: -.01em; white-space: nowrap; color: var(--vp-c-text-1); }

/* Sections */
.section { padding: 96px 0 24px; }
.section-head { max-width: 640px; margin-bottom: 44px; }
.lemon-home h2 { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 0; font-weight: 560; font-size: clamp(36px, 4.4vw, 58px); line-height: 1.04; letter-spacing: -.03em; color: var(--vp-c-text-1); margin: 0; border: 0; padding: 0; }
.lemon-home h2 em { font-variation-settings: 'SOFT' 100, 'WONK' 1; font-weight: 460; }
.section-head > p:last-child:not(.kicker) { font-size: 18px; line-height: 1.6; color: var(--vp-c-text-2); margin: 18px 0 0; }

.features { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 18px; }
.feature, .path { --tone: var(--tone-yellow); position: relative; display: flex; flex-direction: column; padding: 24px; border-radius: 26px; background: color-mix(in srgb, var(--tone) 22%, var(--vp-c-bg)); transition: transform .3s cubic-bezier(.22, 1, .36, 1), background .3s; }
.feature:hover, .path:hover { transform: translateY(-6px) rotate(-.6deg); background: color-mix(in srgb, var(--tone) 36%, var(--vp-c-bg)); }
.feature:hover :deep(.lemon-face), .path:hover .path-face { animation: wiggle .6s ease-in-out; }
.tone-yellow { --tone: var(--tone-yellow) !important; } .tone-green { --tone: var(--tone-green) !important; } .tone-blue { --tone: var(--tone-blue) !important; }
.tone-pink { --tone: var(--tone-pink) !important; } .tone-purple { --tone: var(--tone-purple) !important; } .tone-orange { --tone: var(--tone-orange) !important; } .tone-red { --tone: var(--tone-red) !important; }
.feature-art { position: relative; height: 92px; display: flex; align-items: flex-end; }
.feature-art .crew-b { position: absolute; left: 58px; bottom: 0; }
.feature-art .crew-c { position: absolute; left: 96px; bottom: 2px; }
.feature h3, .path h3 { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100; font-weight: 600; font-size: 23px; line-height: 1.15; letter-spacing: -.02em; margin: 22px 0 10px; color: var(--vp-c-text-1); }
.feature p, .path p { font-size: 15px; line-height: 1.6; color: var(--vp-c-text-2); margin: 0 0 22px; }
.feature-link { margin-top: auto; display: inline-flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 650; color: var(--vp-c-text-1); }
.feature-link span { transition: transform .2s; }
.feature:hover .feature-link span, .path:hover .feature-link span, .text-link:hover span { transform: translateX(4px); }

/* BEAM */
.beam { margin-top: 96px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.05fr); gap: 56px; align-items: center; padding: 56px; border-radius: 36px; background: var(--lemon-ink-panel); color: #ECEDE6; position: relative; overflow: hidden; }
.beam::before { content: ''; position: absolute; inset: 0; background-image: radial-gradient(rgb(255 255 255 / .07) 1px, transparent 1.2px); background-size: 22px 22px; mask-image: radial-gradient(circle at 75% 50%, #000, transparent 70%); pointer-events: none; }
.beam > * { position: relative; }
.beam .kicker { color: #A0A598; }
.beam h2 { color: #F4F2E4 !important; }
.beam-copy p:not(.kicker) { color: #B8BCB0; font-size: 17px; line-height: 1.7; margin: 20px 0 0; max-width: 480px; }
.text-link { display: inline-flex; gap: 8px; margin-top: 26px; font-weight: 650; font-size: 15px; color: var(--lemon-brand) !important; }
.text-link span { transition: transform .2s; }
.tree { display: flex; flex-direction: column; align-items: center; }
.tree-root { display: flex; flex-direction: column; align-items: center; gap: 6px; }
.tree-root span, .worker > span { font-family: var(--vp-font-family-mono); font-size: 12px; color: #A0A598; }
.tree-branches { position: relative; display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; margin-top: 18px; padding-top: 34px; width: 100%; }
.tree-branches::before { content: ''; position: absolute; top: 0; left: 50%; height: 16px; border-left: 2px solid rgb(255 255 255 / .16); }
.tree-branches::after { content: ''; position: absolute; top: 16px; left: 12.5%; right: 12.5%; border-top: 2px solid rgb(255 255 255 / .16); border-radius: 2px; }
.worker { position: relative; display: flex; flex-direction: column; align-items: center; gap: 8px; }
.worker::before { content: ''; position: absolute; top: -18px; height: 18px; border-left: 2px solid rgb(255 255 255 / .16); }
.pulse { position: absolute; top: -21px; left: 50%; width: 7px; height: 7px; margin-left: -3px; border-radius: 50%; background: var(--lemon-brand); box-shadow: 0 0 10px 2px rgb(233 212 116 / .55); opacity: 0; animation: pulse-drop 2.8s calc(var(--i) * .55s + .3s) ease-in infinite; }
.worker-face { position: relative; width: 54px; height: 54px; }
.worker-face :deep(.lemon-face) { position: absolute; inset: 0; }
.worker:not(.crashes):nth-child(1) .worker-face { animation: bob 3.6s ease-in-out infinite; }
.worker:not(.crashes):nth-child(2) .worker-face { animation: bob 4.2s .4s ease-in-out infinite; }
.worker:not(.crashes):nth-child(4) .worker-face { animation: bob 3.9s .8s ease-in-out infinite; }
.worker.crashes .alive { animation: alive 7s ease-in-out infinite; }
.worker.crashes .dead { animation: dead 7s ease-in-out infinite; }
.restart { position: absolute; top: -34px; padding: 3px 9px; border-radius: 999px; background: var(--lemon-brand); color: var(--lemon-ink); font-family: var(--vp-font-family-mono); font-size: 11px; font-style: normal; font-weight: 600; white-space: nowrap; opacity: 0; animation: toast 7s ease-in-out infinite; }
.tree-caption { margin: 30px 0 0; font-family: var(--vp-font-family-mono); font-size: 12px; letter-spacing: .08em; color: #959A8E; }

/* Doors */
/* Subgrid lines up the mocks, titles and copy across doors, so a mock grows to fit its messages without misaligning its neighbours. */
.doors { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 22px; }
.door { display: grid; grid-row: span 3; grid-template-rows: subgrid; row-gap: 0; align-content: start; }
.door h3 { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100; font-weight: 600; font-size: 24px; letter-spacing: -.02em; margin: 20px 0 6px; color: var(--vp-c-text-1); }
.door p { margin: 0; font-size: 15px; line-height: 1.6; color: var(--vp-c-text-2); }
.mock { display: grid; place-items: center; transition: transform .35s cubic-bezier(.22, 1, .36, 1); }
.door:hover .mock { transform: translateY(-6px) rotate(.5deg); }

/* Paths */
.paths { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 20px; }
.path { padding: 30px; }
.path .kicker { margin: 22px 0 0; }
.path h3 { margin-top: 8px; font-size: 27px; }

/* Closing */
.closing { margin: 110px 0 40px; padding: 64px 32px 72px; border-radius: 40px; text-align: center; background: radial-gradient(120% 90% at 50% 0%, color-mix(in srgb, var(--lemon-brand) 55%, var(--vp-c-bg)), var(--vp-c-bg-soft) 70%); }
.closing > p { max-width: 560px; margin: 20px auto 6px; font-size: 18px; line-height: 1.6; color: var(--vp-c-text-2); }
.choir { display: flex; justify-content: center; align-items: flex-end; gap: 10px; margin-bottom: 30px; }
.choir :deep(.lemon-face) { animation: hop 2.8s calc(var(--i) * .14s) cubic-bezier(.34, 1.56, .64, 1) infinite; }
.choir :deep(.lemon-face:hover) { animation: wiggle .55s ease-in-out; }

/* Scroll reveal: below-the-fold blocks rise in once. */
.reveal-pending.reveal-solo, .reveal-pending.reveal-stagger > * { opacity: 0; }
.is-revealed.reveal-solo { animation: rise .9s cubic-bezier(.22, 1, .36, 1) backwards; }
.is-revealed.reveal-stagger > * { animation: rise .8s calc(var(--i, 0) * 110ms) cubic-bezier(.22, 1, .36, 1) backwards; }
.section-head.reveal-stagger > :nth-child(2) { --i: 1; }
.section-head.reveal-stagger > :nth-child(3) { --i: 2; }

@keyframes rise { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }
@keyframes swipe { to { transform: rotate(-1.6deg) scaleX(1); } }
@keyframes float-in { from { opacity: 0; transform: translateY(14px) scale(.9); } to { opacity: 1; transform: none; } }
@keyframes bob { 0%, 100% { transform: translateY(0) rotate(0); } 50% { transform: translateY(-12px) rotate(-2deg); } }
@keyframes breathe { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.04); } }
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes marquee { to { transform: translateX(-50%); } }
@keyframes wiggle { 0%, 100% { transform: rotate(0); } 25% { transform: rotate(-9deg); } 60% { transform: rotate(7deg); } }
@keyframes hop { 0%, 55%, 100% { transform: translateY(0); } 20% { transform: translateY(-16px) rotate(-4deg); } 35% { transform: translateY(0) scaleY(.94); } }
@keyframes alive { 0%, 34% { opacity: 1; transform: none; } 38% { opacity: 1; transform: rotate(-12deg) translateX(-3px); } 41% { opacity: 0; transform: rotate(10deg); } 62% { opacity: 0; transform: scale(.4); } 70% { opacity: 1; transform: scale(1.12); } 76%, 100% { opacity: 1; transform: none; } }
@keyframes peek { from { opacity: 0; transform: translateY(96px); } 50% { opacity: 1; } to { opacity: 1; transform: none; } }
@keyframes slice-in { from { opacity: 0; transform: scale(.7) rotate(-50deg); } to { opacity: 1; transform: none; } }
@keyframes cheer { 0%, 100% { transform: none; } 30% { transform: translateY(-16px) rotate(-5deg); } 55% { transform: scale(1.06, .94); } 75% { transform: translateY(-5px) rotate(3deg); } }
@keyframes juice { 0% { opacity: 1; transform: translate(0, 0) rotate(var(--r)) scale(.3); } 45% { opacity: 1; transform: translate(var(--dx), var(--dy)) rotate(var(--r)) scale(1); } 100% { opacity: 0; transform: translate(calc(var(--dx) * 1.2), calc(var(--dy) + 110px)) rotate(var(--r)) scale(.5); } }
@keyframes shout { from { opacity: 0; transform: translateY(10px) scale(.7) rotate(-6deg); } 25% { opacity: 1; transform: translateY(-8px) scale(1.05) rotate(-3deg); } to { opacity: 0; transform: translateY(-46px) rotate(2deg); } }
@keyframes pulse-drop { 0% { opacity: 0; transform: translateY(0) scale(.6); } 15% { opacity: 1; } 55% { opacity: 1; transform: translateY(18px) scale(1); } 70%, 100% { opacity: 0; transform: translateY(22px) scale(.4); } }
@keyframes dead { 0%, 38% { opacity: 0; transform: none; } 41% { opacity: 1; transform: rotate(8deg); } 52% { opacity: 1; transform: translateY(4px) rotate(14deg); } 60%, 100% { opacity: 0; transform: translateY(18px) rotate(30deg); } }
@keyframes toast { 0%, 66% { opacity: 0; transform: translateY(6px); } 72%, 90% { opacity: 1; transform: none; } 96%, 100% { opacity: 0; transform: translateY(-4px); } }

@media (max-width: 1100px) {
  .features { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .beam { grid-template-columns: minmax(0, 1fr); padding: 44px; }
}
@media (max-width: 900px) {
  .hero { grid-template-columns: minmax(0, 1fr); padding-top: 48px; gap: 12px; }
  .stage { max-width: 560px; width: 100%; margin: 28px auto 0; }
  .doors, .paths { grid-template-columns: 1fr; }
  .mock { max-width: 560px; width: 100%; margin-inline: auto; }
}
@media (max-width: 640px) {
  .lemon-home { padding: 0 20px; }
  .stage { padding-top: 104px; }
  .slice-wrap { top: -16px; right: -74px; width: 300px; height: 300px; }
  .mascot { right: 18px; }
  .mascot :deep(.lemon-face) { width: 150px; height: 150px; }
  .mascot-hint { display: none; }
  .aside-note { top: 4px; left: 0; max-width: 170px; font-size: 14px; }
  .aside-note svg { width: 40px; height: 34px; margin-left: 30px; }
  .beam { padding: 32px 22px; border-radius: 28px; }
  .tree-branches { gap: 4px; }
  .worker-face, .worker-face :deep(.lemon-face) { width: 44px; height: 44px; }
  .closing { padding: 48px 20px 56px; border-radius: 30px; }
  .choir { gap: 4px; }
  .choir :deep(.lemon-face) { width: 40px; height: 40px; }
  .choir :deep(.lemon-face:nth-child(4)) { width: 64px; height: 64px; }
}
@media (prefers-reduced-motion: reduce) {
  .lemon-home *, .lemon-home :deep(*) { animation: none !important; transition: none !important; }
  .hero h1 .move em::after { transform: rotate(-1.6deg); }
  .worker.crashes .dead, .restart, .pulse { display: none; }
}
</style>

<style>
/*
 * Dark mode: lemon is an accent on near-black, never a backdrop behind light
 * text. Unscoped because Vue's scoped :global() drops descendant selectors.
 */
.dark .lemon-home { --lemon-text: #EED985; --dark-card: #191A17; }
.dark .lemon-home .hero h1 .move em, .dark .lemon-home h2 em { color: var(--lemon-text); }
.dark .lemon-home .hero h1 .move em::after { bottom: -.13em; height: .2em; border-radius: 0; opacity: .75; background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 10'%3E%3Cpath d='M0 5 Q10 0 20 5 T40 5' fill='none' stroke='%23E9D474' stroke-width='2.4' stroke-linecap='round'/%3E%3C/svg%3E") left center / auto 100% repeat-x; }
.dark .lemon-home .pill:hover { background: rgb(233 212 116 / .12); color: var(--lemon-text) !important; }
.dark .lemon-home .install, .dark .lemon-home .beam { background: var(--dark-card); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .07); }
.dark .lemon-home .slice-wrap .lemon-slice { opacity: 1; }
.dark .lemon-home .lemon-slice .rind { fill: rgb(233 212 116 / .1); stroke: rgb(233 212 116 / .34); }
.dark .lemon-home .lemon-slice .pith { fill: var(--vp-c-bg); }
.dark .lemon-home .lemon-slice .segment { fill: rgb(233 212 116 / .11); stroke: var(--vp-c-bg); }
.dark .lemon-home .lemon-slice .juice { stroke: rgb(233 212 116 / .16); stroke-opacity: 1; }
.dark .lemon-home .lemon-slice .seeds ellipse { fill: rgb(233 212 116 / .22); stroke: none; }
.dark .lemon-home .slice-wrap::before { background: radial-gradient(circle, rgb(233 212 116 / .16), transparent 62%); }
.dark .lemon-home .orbit { border-color: rgb(255 255 255 / .1); }
.dark .lemon-home .mascot .lemon-face { filter: drop-shadow(0 18px 30px rgb(0 0 0 / .45)); }
.dark .lemon-home .mascot-hint { box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); }
.dark .lemon-home .aside-note svg { color: #E9D474; opacity: .75; }
.dark .lemon-home .feature, .dark .lemon-home .path { background: linear-gradient(160deg, color-mix(in srgb, var(--tone) 12%, var(--dark-card)), var(--dark-card) 62%); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--tone) 16%, transparent); }
.dark .lemon-home .feature:hover, .dark .lemon-home .path:hover { background: linear-gradient(160deg, color-mix(in srgb, var(--tone) 20%, var(--dark-card)), var(--dark-card) 72%); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--tone) 34%, transparent); }
.dark .lemon-home .feature-link { color: color-mix(in srgb, var(--tone) 80%, #fff); }
.dark .lemon-home .path .kicker { color: color-mix(in srgb, var(--tone) 65%, var(--vp-c-text-2)); }
.dark .lemon-home .closing { background: radial-gradient(80% 70% at 50% 0%, rgb(233 212 116 / .13), transparent 72%), var(--dark-card); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .06); }
</style>
