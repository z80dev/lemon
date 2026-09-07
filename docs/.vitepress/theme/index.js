import DefaultTheme from 'vitepress/theme'
import LemonHome from './LemonHome.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('LemonHome', LemonHome)
  },
}
