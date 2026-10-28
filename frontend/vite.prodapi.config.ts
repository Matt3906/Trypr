// TEMPORARY (local testing only, delete after): dev server proxying /api to the prod backend.
import { mergeConfig } from 'vite'
import base from './vite.config.ts'

export default mergeConfig(base, {
  server: { proxy: { '/api': { target: 'https://api.tryprtravel.com', changeOrigin: true, headers: { Origin: 'https://tryprtravel.com' } } } },
})
