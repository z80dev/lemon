<script setup>
import { ref } from 'vue'
import { withBase } from 'vitepress'
import LemonFace from './LemonFace.vue'

const install = 'curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh'
const copied = ref(false)
let copiedTimer
async function copyInstall() {
  try {
    await navigator.clipboard.writeText(install)
    copied.value = true
    clearTimeout(copiedTimer)
    copiedTimer = setTimeout(() => { copied.value = false }, 1800)
  } catch {
    copied.value = false
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
  { color: 'yellow', mood: 'happy', leaf: true, tag: 'Use Lemon', title: 'Your first real conversation.', text: 'Install, connect a provider, start a chat, and come back to the same session tomorrow.', link: '/getting-started/quickstart', label: 'Follow the quickstart' },
  { color: 'green', mood: 'joy', tag: 'Build with Lemon', title: 'Make it your own.', text: 'Explore the agent stack, write reusable skills, and build on the control plane.', link: '/getting-started/build-your-first-agent', label: 'Build your first agent' },
  { color: 'red', mood: 'derp', tag: 'Explore LemonSim', title: 'Put agents to the test.', text: 'Run deterministic, event-sourced simulation worlds with replay verification.', link: '/benchmarks/quickstart', label: 'Enter the arena' },
]

const choir = ['green', 'blue', 'pink', 'yellow', 'purple', 'orange', 'red']
const choirMoods = ['happy', 'joy', 'wink', 'happy', 'surprised', 'joy', 'derp']
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

        <div class="install">
          <span class="prompt" aria-hidden="true">$</span>
          <code>{{ install }}</code>
          <button type="button" class="copy" :class="{ done: copied }" @click="copyInstall">
            <LemonFace :size="18" :mood="copied ? 'joy' : 'happy'" />
            <span>{{ copied ? 'Copied!' : 'Copy' }}</span>
          </button>
          <span class="sr-only" aria-live="polite">{{ copied ? 'Install command copied' : '' }}</span>
        </div>

        <div class="actions">
          <a class="btn primary" :href="withBase('/getting-started/quickstart')">Get started <span aria-hidden="true">→</span></a>
          <a class="btn ghost" href="https://github.com/z80dev/lemon">Star on GitHub <span aria-hidden="true">↗</span></a>
        </div>
        <p class="footnote">Self-hosted · macOS &amp; Linux · Built on Elixir / OTP</p>
      </div>

      <div class="stage" aria-label="Illustration: the Lemon mascot chatting while helper lemons handle subtasks." role="img">
        <div class="sun" aria-hidden="true"></div>
        <div class="orbit" aria-hidden="true"></div>
        <div class="mascot" aria-hidden="true">
          <LemonFace :size="300" leaf blush track />
          <span class="mascot-shadow"></span>
        </div>
        <div class="bubble user" aria-hidden="true">The upload test is flaky again. Can you take a look?</div>
        <div class="bubble bot" aria-hidden="true">
          <LemonFace :size="26" leaf />
          <span>On it — I’ll have a helper read the CI logs while I check the test.</span>
        </div>
        <div class="helper h1" aria-hidden="true"><LemonFace :size="34" color="green" mood="joy" /><span><b>helper</b> reading ci.log</span></div>
        <div class="helper h2" aria-hidden="true"><LemonFace :size="34" color="blue" mood="wink" /><span><b>memory</b> repo conventions</span></div>
        <div class="helper h3" aria-hidden="true"><LemonFace :size="34" color="purple" mood="surprised" /><span><b>tool</b> mix test</span></div>
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
      <header class="section-head">
        <p class="kicker">From a prompt to a practice</p>
        <h2 id="features-title">Good work deserves<br>a place to <em>continue</em>.</h2>
        <p>One runtime for everything an assistant needs beyond its next answer.</p>
      </header>
      <div class="features">
        <a v-for="feature in features" :key="feature.title" class="feature" :class="`tone-${feature.color}`" :href="withBase(feature.link)">
          <div class="feature-art" aria-hidden="true">
            <template v-if="feature.crew">
              <LemonFace :size="64" :color="feature.color" :mood="feature.mood" />
              <LemonFace class="crew-b" :size="40" color="blue" mood="happy" />
              <LemonFace class="crew-c" :size="32" color="pink" mood="wink" />
            </template>
            <LemonFace v-else :size="68" :color="feature.color" :mood="feature.mood" />
          </div>
          <h3>{{ feature.title }}</h3>
          <p>{{ feature.text }}</p>
          <span class="feature-link">{{ feature.label }} <span aria-hidden="true">→</span></span>
        </a>
      </div>
    </section>

    <section class="beam" aria-labelledby="beam-title">
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
          <div v-for="worker in workers" :key="worker.label" class="worker" :class="{ crashes: worker.crashes }">
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
      <header class="section-head">
        <p class="kicker">Wherever you work</p>
        <h2 id="doors-title">One lemon.<br><em>Three doors.</em></h2>
        <p>The same sessions, memory, and tools — from a terminal, a browser tab, or the chat app already on your phone.</p>
      </header>
      <div class="doors">
        <a class="door" :href="withBase('/user-guide/cli')">
          <div class="mock terminal" aria-hidden="true">
            <div class="mock-bar"><i></i><i></i><i></i><span>~/app</span></div>
            <pre><span class="dim">$</span> lemon
<span class="lm">●</span> <b>lemon</b> <span class="dim">· session upload-fix</span>
<span class="dim">you   ›</span> why is upload_test flaky?
<span class="lm">lemon ›</span> Two tests share a temp dir.
        Patch ready — running it now.
<span class="ok">✓</span> <span class="dim">bash</span> mix test test/upload_test.exs</pre>
          </div>
          <h3>Terminal</h3>
          <p>A fast TUI for long coding sessions, with slash commands and resumable history.</p>
        </a>
        <a class="door" :href="withBase('/user-guide/web')">
          <div class="mock browser" aria-hidden="true">
            <div class="mock-bar"><i></i><i></i><i></i><span class="url">lemon · sessions</span></div>
            <div class="mock-chat">
              <div class="msg me">Summarize what changed this week.</div>
              <div class="msg them"><LemonFace :size="22" leaf /><span>12 commits, 3 merged PRs. The big one: retries in the outbox.</span></div>
            </div>
          </div>
          <h3>Browser</h3>
          <p>Pick up any session in the web interface, with files, runs, and history alongside.</p>
        </a>
        <a class="door" :href="withBase('/getting-started/add-a-channel')">
          <div class="mock phone" aria-hidden="true">
            <div class="phone-head"><LemonFace :size="24" leaf /><span><b>Lemon</b><small>bot</small></span></div>
            <div class="mock-chat">
              <div class="msg them">Morning! Your release notes are drafted.</div>
              <div class="msg me">Ship it 🍋</div>
            </div>
          </div>
          <h3>Chat</h3>
          <p>Talk to the same assistant from Telegram, Discord, and other channels.</p>
        </a>
      </div>
    </section>

    <section class="section paths-section" aria-labelledby="paths-title">
      <header class="section-head">
        <p class="kicker">Pick your starting point</p>
        <h2 id="paths-title">Make something <em>happen</em>.</h2>
      </header>
      <div class="paths">
        <a v-for="path in paths" :key="path.tag" :href="withBase(path.link)" class="path" :class="`tone-${path.color}`">
          <LemonFace class="path-face" :size="56" :color="path.color" :mood="path.mood" :leaf="path.leaf" />
          <span class="kicker">{{ path.tag }}</span>
          <h3>{{ path.title }}</h3>
          <p>{{ path.text }}</p>
          <span class="feature-link">{{ path.label }} <span aria-hidden="true">→</span></span>
        </a>
      </div>
    </section>

    <section class="closing" aria-labelledby="closing-title">
      <div class="choir" aria-hidden="true">
        <LemonFace v-for="(color, index) in choir" :key="color" :size="index === 3 ? 92 : 58" :color="color" :mood="choirMoods[index]" :leaf="index === 3" :blush="index === 3" :style="{ '--i': index }" />
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

.install { display: flex; align-items: center; gap: 10px; margin-top: 30px; max-width: 540px; padding: 7px 7px 7px 16px; border-radius: 16px; background: var(--lemon-ink-panel); color: #ECEDE6; box-shadow: 0 1px 0 rgb(255 255 255 / .06) inset, 0 18px 40px -24px rgb(20 26 16 / .6); animation: rise .8s .32s cubic-bezier(.22, 1, .36, 1) both; }
.install .prompt { color: var(--lemon-brand); font-family: var(--vp-font-family-mono); font-weight: 700; }
.install code { flex: 1; min-width: 0; overflow-x: auto; white-space: nowrap; scrollbar-width: none; font-family: var(--vp-font-family-mono); font-size: 13px; color: #ECEDE6; background: none; padding: 6px 0; }
.install code::-webkit-scrollbar { display: none; }
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

.stage { position: relative; height: 560px; }
.sun { position: absolute; inset: 70px 30px 60px 60px; border-radius: 50%; background: radial-gradient(circle at 40% 35%, color-mix(in srgb, var(--lemon-brand) 70%, transparent), color-mix(in srgb, var(--lemon-brand) 18%, transparent) 62%, transparent 72%); filter: blur(2px); animation: breathe 7s ease-in-out infinite; }
.orbit { position: absolute; inset: 40px 0 30px 30px; border-radius: 50%; border: 1.5px dashed color-mix(in srgb, var(--vp-c-text-1) 16%, transparent); animation: spin 80s linear infinite; }
:global(.dark) .sun { background: radial-gradient(circle at 40% 35%, rgb(233 212 116 / .34), rgb(233 212 116 / .08) 62%, transparent 72%); }
:global(.dark) .hero h1 .move em::after { background: rgb(233 212 116 / .42); }
.mascot { position: absolute; left: 50%; top: 52%; translate: -50% -50%; animation: pop .9s .1s cubic-bezier(.34, 1.56, .64, 1) both; }
.mascot :deep(.lemon-face) { position: relative; z-index: 1; animation: bob 4.8s ease-in-out infinite; filter: drop-shadow(0 18px 24px rgb(80 70 10 / .18)); }
.mascot-shadow { position: absolute; left: 18%; right: 18%; bottom: -26px; height: 22px; border-radius: 50%; background: rgb(30 35 20 / .14); filter: blur(6px); animation: shadow 4.8s ease-in-out infinite; }
.bubble { position: absolute; max-width: 270px; padding: 11px 15px; border-radius: 20px; font-size: 14px; line-height: 1.45; box-shadow: 0 10px 30px -14px rgb(30 35 20 / .35); z-index: 2; }
.bubble.user { top: 18px; right: 0; background: var(--lemon-brand); color: var(--lemon-ink); border-bottom-right-radius: 6px; animation: float-in .7s .7s cubic-bezier(.34, 1.56, .64, 1) both; }
.bubble.bot { bottom: 26px; left: 0; display: flex; gap: 10px; align-items: flex-start; background: var(--vp-c-bg-elv); color: var(--vp-c-text-1); border-bottom-left-radius: 6px; animation: float-in .7s 1.4s cubic-bezier(.34, 1.56, .64, 1) both; }
.helper { position: absolute; z-index: 2; display: flex; align-items: center; gap: 8px; padding: 5px 13px 5px 6px; border-radius: 999px; background: var(--vp-c-bg-elv); font-size: 12.5px; color: var(--vp-c-text-2); box-shadow: 0 8px 24px -14px rgb(30 35 20 / .4); white-space: nowrap; }
.helper b { color: var(--vp-c-text-1); font-weight: 650; margin-right: 3px; }
.helper.h1 { top: 130px; left: -6px; animation: float-in .6s 2s cubic-bezier(.34, 1.56, .64, 1) both, drift 6s 2.6s ease-in-out infinite; }
.helper.h2 { top: 250px; right: -14px; animation: float-in .6s 2.3s cubic-bezier(.34, 1.56, .64, 1) both, drift 7s 2.9s ease-in-out infinite reverse; }
.helper.h3 { bottom: 120px; right: 24px; animation: float-in .6s 2.6s cubic-bezier(.34, 1.56, .64, 1) both, drift 6.5s 3.2s ease-in-out infinite; }

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
.worker-face { position: relative; width: 54px; height: 54px; }
.worker-face :deep(.lemon-face) { position: absolute; inset: 0; }
.worker:not(.crashes):nth-child(1) .worker-face { animation: bob 3.6s ease-in-out infinite; }
.worker:not(.crashes):nth-child(2) .worker-face { animation: bob 4.2s .4s ease-in-out infinite; }
.worker:not(.crashes):nth-child(4) .worker-face { animation: bob 3.9s .8s ease-in-out infinite; }
.worker.crashes .alive { animation: alive 7s ease-in-out infinite; }
.worker.crashes .dead { animation: dead 7s ease-in-out infinite; }
.restart { position: absolute; top: -34px; padding: 3px 9px; border-radius: 999px; background: var(--lemon-brand); color: var(--lemon-ink); font-family: var(--vp-font-family-mono); font-size: 11px; font-style: normal; font-weight: 600; white-space: nowrap; opacity: 0; animation: toast 7s ease-in-out infinite; }
.tree-caption { margin: 30px 0 0; font-family: var(--vp-font-family-mono); font-size: 12px; letter-spacing: .08em; color: #70756B; }

/* Doors */
.doors { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 22px; }
.door { display: flex; flex-direction: column; }
.door h3 { font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100; font-weight: 600; font-size: 24px; letter-spacing: -.02em; margin: 20px 0 6px; color: var(--vp-c-text-1); }
.door p { margin: 0; font-size: 15px; line-height: 1.6; color: var(--vp-c-text-2); }
.mock { height: 220px; border-radius: 22px; overflow: hidden; transition: transform .35s cubic-bezier(.22, 1, .36, 1); box-shadow: 0 1px 0 rgb(0 0 0 / .03), 0 20px 40px -30px rgb(30 35 20 / .45); }
.door:hover .mock { transform: translateY(-6px) rotate(.5deg); }
.mock-bar { display: flex; align-items: center; gap: 6px; padding: 12px 14px; font-size: 11px; }
.mock-bar i { width: 9px; height: 9px; border-radius: 50%; background: currentColor; opacity: .22; }
.mock-bar span { margin-left: 8px; font-family: var(--vp-font-family-mono); opacity: .55; }
.terminal { background: var(--lemon-ink-panel); color: #ECEDE6; }
.terminal pre { margin: 0; padding: 4px 18px; font-family: var(--vp-font-family-mono); font-size: 12px; line-height: 1.75; white-space: pre; }
.terminal .dim { color: #858A7E; } .terminal .lm { color: #E9D474; } .terminal .ok { color: #8CCB98; } .terminal b { color: #F4F2E4; }
.browser { background: var(--vp-c-bg-elv); border: 1px solid var(--vp-c-divider); color: var(--vp-c-text-1); }
.browser .mock-bar { border-bottom: 1px solid var(--vp-c-divider); }
.browser .url { flex: 1; text-align: center; padding: 3px 10px; border-radius: 8px; background: var(--vp-c-bg-soft); }
.mock-chat { display: flex; flex-direction: column; gap: 10px; padding: 18px; font-size: 13px; line-height: 1.45; }
.msg { max-width: 82%; padding: 9px 13px; border-radius: 18px; }
.msg.me { align-self: flex-end; background: var(--lemon-brand); color: var(--lemon-ink); border-bottom-right-radius: 6px; }
.msg.them { align-self: flex-start; display: flex; gap: 8px; align-items: flex-start; background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); border-bottom-left-radius: 6px; }
.phone { background: color-mix(in srgb, var(--tone-blue) 30%, var(--vp-c-bg)); color: var(--vp-c-text-1); }
.phone-head { display: flex; align-items: center; gap: 10px; padding: 13px 16px; background: color-mix(in srgb, var(--vp-c-bg-elv) 70%, transparent); font-size: 13px; }
.phone-head small { display: block; font-size: 11px; color: var(--vp-c-text-3); }
.phone .msg.them { background: var(--vp-c-bg-elv); }

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

@keyframes rise { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }
@keyframes swipe { to { transform: rotate(-1.6deg) scaleX(1); } }
@keyframes pop { from { opacity: 0; transform: scale(.6) rotate(-12deg); } to { opacity: 1; transform: none; } }
@keyframes float-in { from { opacity: 0; transform: translateY(14px) scale(.9); } to { opacity: 1; transform: none; } }
@keyframes bob { 0%, 100% { transform: translateY(0) rotate(0); } 50% { transform: translateY(-12px) rotate(-2deg); } }
@keyframes shadow { 0%, 100% { transform: scaleX(1); opacity: 1; } 50% { transform: scaleX(.82); opacity: .6; } }
@keyframes drift { 0%, 100% { translate: 0 0; } 50% { translate: 0 -8px; } }
@keyframes breathe { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.04); } }
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes marquee { to { transform: translateX(-50%); } }
@keyframes wiggle { 0%, 100% { transform: rotate(0); } 25% { transform: rotate(-9deg); } 60% { transform: rotate(7deg); } }
@keyframes hop { 0%, 55%, 100% { transform: translateY(0); } 20% { transform: translateY(-16px) rotate(-4deg); } 35% { transform: translateY(0) scaleY(.94); } }
@keyframes alive { 0%, 34% { opacity: 1; transform: none; } 38% { opacity: 1; transform: rotate(-12deg) translateX(-3px); } 41% { opacity: 0; transform: rotate(10deg); } 62% { opacity: 0; transform: scale(.4); } 70% { opacity: 1; transform: scale(1.12); } 76%, 100% { opacity: 1; transform: none; } }
@keyframes dead { 0%, 38% { opacity: 0; transform: none; } 41% { opacity: 1; transform: rotate(8deg); } 52% { opacity: 1; transform: translateY(4px) rotate(14deg); } 60%, 100% { opacity: 0; transform: translateY(18px) rotate(30deg); } }
@keyframes toast { 0%, 66% { opacity: 0; transform: translateY(6px); } 72%, 90% { opacity: 1; transform: none; } 96%, 100% { opacity: 0; transform: translateY(-4px); } }

@media (max-width: 1100px) {
  .features { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .beam { grid-template-columns: minmax(0, 1fr); padding: 44px; }
}
@media (max-width: 900px) {
  .hero { grid-template-columns: minmax(0, 1fr); padding-top: 48px; gap: 12px; }
  .stage { height: 500px; max-width: 560px; width: 100%; margin: 0 auto; }
  .doors, .paths { grid-template-columns: 1fr; }
  .mock { max-width: 560px; }
}
@media (max-width: 640px) {
  .lemon-home { padding: 0 20px; }
  .stage { height: 460px; }
  .sun { inset: 70px 10px 70px 10px; }
  .orbit { inset: 50px -10px 50px -10px; }
  .features { grid-template-columns: 1fr; }
  .mascot :deep(.lemon-face) { width: 210px; height: 210px; }
  .bubble { max-width: 230px; font-size: 13px; }
  .bubble.user { top: 0; }
  .bubble.bot { bottom: 0; }
  .helper.h1 { top: 100px; left: 0; }
  .helper.h2 { top: auto; bottom: 100px; right: 0; }
  .helper.h3 { display: none; }
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
  .worker.crashes .dead, .restart { display: none; }
}
</style>
