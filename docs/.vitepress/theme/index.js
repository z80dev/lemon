import { h } from 'vue'
import DefaultTheme from 'vitepress/theme'
import '@fontsource-variable/fraunces/full.css'
import '@fontsource-variable/fraunces/full-italic.css'
import '@fontsource-variable/instrument-sans/wght.css'
import '@fontsource-variable/jetbrains-mono/wght.css'
import LemonFace from './LemonFace.vue'
import LemonHome from './LemonHome.vue'
import LemonNotFound from './LemonNotFound.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, { 'not-found': () => h(LemonNotFound) }),
  enhanceApp({ app }) {
    app.component('LemonFace', LemonFace)
    app.component('LemonHome', LemonHome)
  },
}
