<script setup>
import { withBase } from 'vitepress'
import LemonFace from './LemonFace.vue'
</script>

<template>
  <div class="lemon-404">
    <div class="face">
      <LemonFace :size="190" mood="derp" leaf blush track />
      <span class="q q1" aria-hidden="true">?</span>
      <span class="q q2" aria-hidden="true">?</span>
    </div>
    <p class="code">404</p>
    <h1>This page got squeezed out.</h1>
    <p class="lede">Lemon looked everywhere, including under the leaf. The link may be old, or the page moved.</p>
    <div class="actions">
      <a class="btn primary" :href="withBase('/')">Take me home</a>
      <a class="btn ghost" :href="withBase('/README')">Browse all docs</a>
    </div>
  </div>
</template>

<style scoped>
.lemon-404 { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 72px 24px 96px; }
.face { position: relative; animation: tilt 5s ease-in-out infinite; }
.q { position: absolute; font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 1; font-weight: 700; color: var(--lemon-brand-deep); }
.q1 { top: -6px; right: -26px; font-size: 48px; animation: hover-q 2.6s ease-in-out infinite; }
.q2 { top: 30px; right: -56px; font-size: 30px; animation: hover-q 2.6s .5s ease-in-out infinite; }
.code { margin: 28px 0 0; font-family: var(--vp-font-family-mono); font-size: 13px; letter-spacing: .3em; color: var(--vp-c-text-3); }
h1 { margin: 10px 0 0; font-family: var(--lemon-display); font-variation-settings: 'SOFT' 100, 'WONK' 1; font-weight: 600; font-size: clamp(34px, 5vw, 56px); line-height: 1.05; letter-spacing: -.03em; color: var(--vp-c-text-1); }
.lede { max-width: 440px; margin: 16px 0 0; font-size: 17px; line-height: 1.6; color: var(--vp-c-text-2); }
.actions { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; margin-top: 30px; }
.btn { display: inline-flex; padding: 12px 22px; border-radius: 999px; font-weight: 650; text-decoration: none; transition: transform .18s, box-shadow .18s; }
.btn.primary { background: var(--lemon-brand); color: var(--lemon-ink); box-shadow: 0 3px 0 var(--lemon-brand-deep); }
.btn.ghost { background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.btn:hover { transform: translateY(-2px); }
@keyframes tilt { 0%, 100% { transform: rotate(-4deg); } 50% { transform: rotate(5deg); } }
@keyframes hover-q { 0%, 100% { transform: translateY(0) rotate(8deg); } 50% { transform: translateY(-8px) rotate(-4deg); } }
@media (prefers-reduced-motion: reduce) { .face, .q { animation: none; } }
</style>
