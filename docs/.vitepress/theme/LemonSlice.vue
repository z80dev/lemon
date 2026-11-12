<script setup>
// A lemon cross-section: rind, pith, ten segments with juice vesicles and a
// few seeds. Purely decorative; geometry is computed once.
import { useId } from 'vue'

const COUNT = 10
const INNER = 9
const OUTER = 80
const id = useId()
const round = (value) => Math.round(value * 100) / 100
const at = (radius, angle) => `${round(radius * Math.cos(angle))} ${round(radius * Math.sin(angle))}`

const segments = Array.from({ length: COUNT }, (_, index) => {
  const start = (index / COUNT) * Math.PI * 2
  const end = ((index + 1) / COUNT) * Math.PI * 2
  const middle = (start + end) / 2
  const width = end - start
  return {
    d: `M${at(INNER, start)} L${at(OUTER, start)} A${OUTER} ${OUTER} 0 0 1 ${at(OUTER, end)} L${at(INNER, end)} A${INNER} ${INNER} 0 0 0 ${at(INNER, start)} Z`,
    juice: [-0.24, 0, 0.24].map((offset) => `M${at(30 + Math.abs(offset) * 30, middle + offset * width)} L${at(66, middle + offset * width * 1.2)}`).join(' '),
    seed: index % 3 === 1 ? { x: round(26 * Math.cos(middle)), y: round(26 * Math.sin(middle)), angle: round((middle * 180) / Math.PI) } : null,
  }
})
</script>

<template>
  <svg class="lemon-slice" viewBox="-100 -100 200 200" aria-hidden="true" focusable="false">
    <defs>
      <radialGradient :id="`${id}-flesh`" r="0.6">
        <stop offset="0" stop-color="#FBF0B4" />
        <stop offset="1" stop-color="#F0D663" />
      </radialGradient>
    </defs>
    <circle r="98" class="rind" />
    <circle r="91" class="pith" />
    <g class="segments">
      <path v-for="(segment, index) in segments" :key="index" :d="segment.d" :fill="`url(#${id}-flesh)`" class="segment" />
    </g>
    <path :d="segments.map((segment) => segment.juice).join(' ')" class="juice" />
    <g class="seeds">
      <template v-for="(segment, index) in segments" :key="index">
        <ellipse v-if="segment.seed" :cx="segment.seed.x" :cy="segment.seed.y" rx="6" ry="2.8" :transform="`rotate(${segment.seed.angle} ${segment.seed.x} ${segment.seed.y})`" />
      </template>
    </g>
    <circle r="5.5" class="pith" />
  </svg>
</template>

<style scoped>
.lemon-slice { display: block; width: 100%; height: 100%; overflow: visible; }
.rind { fill: #EDD56C; stroke: #D7BD4F; stroke-width: 1.5; }
.pith { fill: #FBF6DD; }
.segment { stroke: #FBF6DD; stroke-width: 4.5; stroke-linejoin: round; }
.juice { fill: none; stroke: #fff; stroke-opacity: .45; stroke-width: 2.4; stroke-linecap: round; }
.seeds ellipse { fill: #FFF9E6; stroke: #E2CB6A; stroke-width: 1; }
</style>
