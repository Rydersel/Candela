import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base './' so the static build works from any host path (GitHub Pages included)
export default defineConfig({
  base: './',
  plugins: [react()],
})
