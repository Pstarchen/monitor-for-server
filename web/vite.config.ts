import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import Components from 'unplugin-vue-components/vite'
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers'
import { fileURLToPath, URL } from 'node:url'

export default defineConfig({
  plugins: [
    vue(),
    Components({
      dts: false,
      resolvers: [ElementPlusResolver({ importStyle: 'css' })],
    }),
  ],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5173,
    proxy: {
      '/api/setup': { target: 'http://127.0.0.1:8090', changeOrigin: true },
      '/api': { target: 'http://127.0.0.1:8081', changeOrigin: true },
      '/actuator': { target: 'http://127.0.0.1:8081', changeOrigin: true },
      '/ws': { target: 'ws://127.0.0.1:8081', ws: true },
    },
  },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
})
