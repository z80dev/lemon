<script setup>
import { withBase } from 'vitepress'

const features = [
  { number: '01', title: 'Context that stays with you.', text: 'Return to durable sessions, search useful memory, and turn repeatable workflows into skills. Keep your project conventions close to the work.', link: '/user-guide/memory', label: 'Explore memory' },
  { number: '02', title: 'More than one pair of hands.', text: 'Delegate to native subagents in the same runtime, or send work to a named execution node. Coordinate the work from one conversation.', link: '/architecture/overview', label: 'Meet the runtime' },
  { number: '03', title: 'Your choice of model.', text: 'Configure providers and models through one platform. Keep files and runtime state on your machine while using the model providers you choose.', link: '/user-guide/setup', label: 'Set up your provider' },
  { number: '04', title: 'Built to be understood.', text: 'Inspect runs, validate configuration, diagnose setup, and back up durable state. Real tools for the work after “hello world.”', link: '/support', label: 'See the support tools' },
]
const paths = [
  { tag: 'USE LEMON', title: 'Your first real conversation.', text: 'Install, connect a provider, start a chat, and come back to the same session.', link: '/getting-started/quickstart', label: 'Follow the quickstart' },
  { tag: 'BUILD WITH LEMON', title: 'Make it your own.', text: 'Explore the agent stack, create reusable skills, and build on the control plane.', link: '/getting-started/build-your-first-agent', label: 'Build your first agent' },
  { tag: 'EXPLORE LEMONSIM', title: 'Put agents to the test.', text: 'Run deterministic, event-sourced simulation worlds with replay verification.', link: '/benchmarks/quickstart', label: 'Explore the benchmark arena' },
]
</script>

<template>
  <div class="lemon-home">
    <section class="lemon-hero" aria-labelledby="hero-title">
      <div class="hero-copy">
        <a class="eyebrow release-pill" :href="withBase('/install')"><span class="status-dot"></span> OPEN SOURCE · PRE-1.0 <span aria-hidden="true">↗</span></a>
        <h1 id="hero-title">Your agents.<br>Your machine.<br><span>Your move.</span></h1>
        <p class="hero-description">Meet Lemon. A local-first AI assistant that brings your models, tools, and conversations together — and keeps useful context close.</p>
        <div class="hero-actions"><a class="lemon-button primary" :href="withBase('/getting-started/quickstart')">Get started <span aria-hidden="true">↗</span></a><a class="lemon-button secondary" href="https://github.com/z80dev/lemon">Explore the code <span aria-hidden="true">→</span></a></div>
        <p class="hero-footnote">Self-hosted. MIT licensed. Built on Elixir / OTP.</p>
      </div>
      <div class="runtime-art" role="img" aria-label="Conceptual architecture: terminal, web, and chat connect to a local Lemon runtime with sessions, tools, memory, and model providers.">
        <div class="art-grid"></div>
        <div class="art-caption"><span class="status-dot"></span> A LITTLE RUNTIME. A LOT OF POSSIBILITY.</div>
        <div class="interface-row"><span>⌘ Terminal</span><span>▣ Browser</span><span>↗ Chat</span></div>
        <div class="connector connector-top"></div>
        <div class="runtime-core"><img :src="withBase('/brand/lemon-mark.svg')" alt="" width="64" height="64"><div><strong>lemon</strong><span>YOUR LOCAL RUNTIME</span></div><span class="core-dot"></span></div>
        <div class="capability-row"><span>Sessions</span><span>Tools</span><span>Memory</span></div>
        <div class="connector connector-bottom"></div>
        <div class="provider-row"><span class="provider-symbol">✳</span><div><strong>The models you choose</strong><span>Connected through your providers</span></div></div>
        <div class="art-bottom"><span>LOCAL STATE. CONNECTED INTELLIGENCE.</span><span aria-hidden="true">↗</span></div>
      </div>
    </section>

    <div class="principles" aria-label="Platform principles"><span>Durable sessions</span><i aria-hidden="true">✳</i><span>Native subagents</span><i aria-hidden="true">✳</i><span>Provider choice</span><i aria-hidden="true">✳</i><span>Supervised execution</span></div>

    <section class="home-section" aria-labelledby="features-title">
      <div class="section-heading"><p class="eyebrow">FROM A PROMPT TO A PRACTICE</p><h2 id="features-title">Good work deserves<br>a place to continue.</h2><p>One runtime for the things an assistant needs beyond its next answer.</p></div>
      <div class="feature-grid"><article v-for="feature in features" :key="feature.number" class="feature-card"><span class="feature-number">{{ feature.number }} /</span><h3>{{ feature.title }}</h3><p>{{ feature.text }}</p><a :href="withBase(feature.link)">{{ feature.label }} <span aria-hidden="true">↗</span></a></article></div>
    </section>

    <section class="beam-section" aria-labelledby="beam-title"><div><p class="eyebrow">SOLID FOUNDATIONS. FRESH POSSIBILITIES.</p><h2 id="beam-title">Agents are a<br>concurrency problem.</h2><p>Tools run. Messages arrive. Sessions wait. Work gets delegated. Lemon uses the BEAM's lightweight processes and supervision to give that activity a structure you can reason about.</p><a class="text-link" :href="withBase('/why-beam-for-agents')">Why we built on the BEAM <span aria-hidden="true">↗</span></a></div><div class="beam-diagram" aria-hidden="true"><span class="diagram-label">ONE SUPERVISED RUNTIME</span><div class="beam-root">Lemon / OTP</div><div class="beam-branches"><span>Agent<br><small>session</small></span><span>Agent<br><small>session</small></span><span>Agent<br><small>session</small></span></div><p>Independent processes.<br>Shared foundations.</p></div></section>

    <section class="home-section paths-section" aria-labelledby="paths-title"><div class="section-heading"><p class="eyebrow">PICK YOUR STARTING POINT</p><h2 id="paths-title">Make something happen.</h2></div><div class="path-grid"><a v-for="path in paths" :key="path.tag" :href="withBase(path.link)" class="path-card"><span class="eyebrow">{{ path.tag }}</span><h3>{{ path.title }}</h3><p>{{ path.text }}</p><span class="path-link">{{ path.label }} <span aria-hidden="true">↗</span></span></a></div></section>

    <section class="closing-section" aria-labelledby="closing-title"><div><p class="eyebrow">BUILT IN THE OPEN</p><h2 id="closing-title">Early days.<br>Real building blocks.</h2><p>Lemon is pre-1.0 and evolving. Start with the supported install path, explore the documented capabilities, and help shape what comes next.</p></div><div class="closing-actions"><a class="lemon-button primary" :href="withBase('/install')">Install Lemon <span aria-hidden="true">↗</span></a><a class="text-link" :href="withBase('/compare')">Capabilities &amp; boundaries <span aria-hidden="true">→</span></a></div></section>
  </div>
</template>
