<script setup>
// The Lemon mascot, drawn from the Lemon Bot design system: the same soft
// lemon blob, wonky eyes, leaf, and per-Bot palettes used by every client.
import { computed, onBeforeUnmount, onMounted, ref, useId } from 'vue'

const props = defineProps({
  color: { type: String, default: 'yellow' },
  mood: { type: String, default: 'happy' }, // happy | joy | wink | surprised | sleepy | derp | crashed
  size: { type: [Number, String], default: 48 },
  leaf: { type: Boolean, default: false },
  blush: { type: Boolean, default: false },
  track: { type: Boolean, default: false },
  label: { type: String, default: '' },
})

const BLOB = 'M0.83 71.82 C1.00 67.93 2.87 60.73 5.22 54.60 C2.70 29.01 11.75 12.25 29.78 4.20 C48.86 -4.32 67.38 0.13 82.74 17.43 C88.88 19.78 95.48 23.19 98.97 26.72 C99.80 31.44 97.87 39.93 96.06 45.83 C99.11 71.17 88.52 87.34 69.44 95.87 C50.35 104.39 31.83 99.94 15.53 80.52 C9.92 77.93 3.79 75.59 0.83 71.82 Z'
const PALETTE = { yellow: '#EDD56C', lemon: '#E9D474', green: '#A3CA98', blue: '#A0C4EA', pink: '#E3AEC3', purple: '#BDB2E3', orange: '#EBB487', red: '#E6A79F' }

const fill = computed(() => PALETTE[props.color] || props.color)
const openEyes = computed(() => ['happy', 'surprised', 'derp'].includes(props.mood))
const gradient = `lemon-hl-${useId()}`
const root = ref(null)
const look = ref({ x: 0, y: 0 })

function follow(event) {
  const box = root.value?.getBoundingClientRect()
  if (!box) return
  const dx = event.clientX - (box.left + box.width * 0.55)
  const dy = event.clientY - (box.top + box.height * 0.4)
  const distance = Math.hypot(dx, dy) || 1
  const reach = Math.min(1, distance / 420)
  look.value = { x: (dx / distance) * 3.4 * reach, y: (dy / distance) * 2.6 * reach }
}

onMounted(() => {
  if (props.track && !matchMedia('(prefers-reduced-motion: reduce)').matches) window.addEventListener('pointermove', follow, { passive: true })
})
onBeforeUnmount(() => window.removeEventListener('pointermove', follow))
</script>

<template>
  <svg
    ref="root"
    class="lemon-face"
    :class="`mood-${mood}`"
    :width="size"
    :height="size"
    viewBox="-4 -4 108 108"
    :role="label ? 'img' : undefined"
    :aria-label="label || undefined"
    :aria-hidden="label ? undefined : 'true'"
    focusable="false"
  >
    <defs>
      <radialGradient :id="gradient" cx="30%" cy="22%" r="55%">
        <stop offset="0" stop-color="#fff" stop-opacity=".36" />
        <stop offset="1" stop-color="#fff" stop-opacity="0" />
      </radialGradient>
    </defs>
    <path :d="BLOB" :fill="fill" />
    <path :d="BLOB" :fill="`url(#${gradient})`" />
    <path :d="BLOB" fill="none" stroke="#000" stroke-opacity=".07" stroke-width="1.4" />
    <ellipse v-if="leaf" cx="80" cy="14" rx="15" ry="9" transform="rotate(-28 80 14)" fill="#6E9A5B" />
    <g v-if="blush" fill="#E2807F" fill-opacity=".34">
      <ellipse cx="36.5" cy="56" rx="6.2" ry="3.6" transform="rotate(-8 36.5 56)" />
      <ellipse cx="76" cy="49.5" rx="6.2" ry="3.6" transform="rotate(-8 76 49.5)" />
    </g>
    <g class="lemon-features" fill="#27301F" fill-opacity=".88" stroke="#27301F" stroke-opacity=".88" stroke-linecap="round" stroke-linejoin="round" :style="{ transform: `translate(${look.x}px, ${look.y}px)` }">
      <g v-if="openEyes" class="lemon-eyes" stroke="none">
        <template v-if="mood === 'derp'">
          <ellipse cx="46.5" cy="43" rx="3.3" ry="5.4" transform="rotate(10.3 46.5 43)" />
          <ellipse cx="64" cy="38" rx="6.2" ry="10.2" transform="rotate(6.9 64 38)" />
        </template>
        <template v-else>
          <ellipse cx="47" cy="42" rx="4.2" ry="7" transform="rotate(10.3 47 42)" />
          <ellipse cx="63" cy="38.5" rx="4.8" ry="8.2" transform="rotate(6.9 63 38.5)" />
        </template>
      </g>
      <g v-else-if="mood === 'wink'">
        <ellipse cx="47" cy="42" rx="4.2" ry="7" transform="rotate(10.3 47 42)" stroke="none" />
        <path d="M58 40.5 Q63 33.5 68 39.5" fill="none" stroke-width="4.2" />
      </g>
      <g v-else-if="mood === 'joy'" fill="none" stroke-width="4.2">
        <path d="M42.5 44 Q47 36.5 51.5 43" />
        <path d="M58 40.5 Q63 32.5 68 39.5" />
      </g>
      <g v-else-if="mood === 'sleepy'" fill="none" stroke-width="4">
        <path d="M42.5 41.5 Q47 46.5 51.5 42.5" />
        <path d="M58 38.5 Q63 43.5 68 39" />
      </g>
      <g v-else-if="mood === 'crashed'" fill="none" stroke-width="3.8">
        <path d="M43 38.5 L51 46.5 M51 38.5 L43 46.5" />
        <path d="M59 34.5 L67 42.5 M67 34.5 L59 42.5" />
      </g>

      <ellipse v-if="mood === 'surprised'" cx="58.5" cy="60" rx="3.8" ry="4.8" stroke="none" />
      <ellipse v-else-if="mood === 'sleepy'" cx="58" cy="59" rx="2.6" ry="2.2" stroke="none" />
      <path v-else-if="mood === 'joy'" d="M47.5 55.5 Q58.5 72 69 52.5 Z" stroke-width="2" />
      <path v-else-if="mood === 'crashed'" d="M47.5 60 q3 -3.4 6 0 t6 0 t6 0" fill="none" stroke-width="3.6" />
      <template v-else-if="mood === 'derp'">
        <path d="M57.5 60.5 q2.5 7 7.5 1.5" fill="#E58585" fill-opacity="1" stroke="none" />
        <path d="M47 59 Q53 63.5 58 60.5 Q63 57.5 67.5 58.5" fill="none" stroke-width="4.2" />
      </template>
      <path v-else d="M49 58.5 Q58.5 66 66.5 55.5" fill="none" stroke-width="4.5" />
    </g>
  </svg>
</template>

<style scoped>
.lemon-face { display: block; overflow: visible; flex: none; }
.lemon-features { transition: transform 260ms cubic-bezier(.22, 1, .36, 1); }
.lemon-eyes { transform-box: fill-box; transform-origin: center; animation: lemon-blink var(--blink-every, 5.2s) var(--blink-delay, 0s) infinite; }
@keyframes lemon-blink {
  0%, 92%, 100% { transform: scaleY(1); }
  95% { transform: scaleY(.12); }
}
@media (prefers-reduced-motion: reduce) {
  .lemon-eyes { animation: none; }
  .lemon-features { transition: none; }
}
</style>
