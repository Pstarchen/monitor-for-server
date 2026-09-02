import { createApp } from 'vue'
import { createPinia } from 'pinia'
// Programmatic services are not discovered by the template auto-import plugin.
// Keep their styles explicit so MessageBox/Message do not render as unstyled HTML.
import 'element-plus/es/components/message-box/style/css'
import 'element-plus/es/components/message/style/css'
import 'element-plus/theme-chalk/dark/css-vars.css'
import './styles.css'
import App from './App.vue'
import router from './router'

const app = createApp(App)
app.use(createPinia())
app.use(router)
app.mount('#app')
