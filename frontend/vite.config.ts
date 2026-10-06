import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5173,
    proxy: {
      // Local FastAPI backend (see app/main.py)
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: true },
    },
  },
  build: { chunkSizeWarningLimit: 1500 },
})
