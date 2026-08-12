import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// GITHUB_REPOSITORY is set automatically in Actions ("owner/repo"); the base
// path derives from it so the repo name never appears in source. Locally the
// app serves from '/'. Renaming the repo or moving to a custom domain is a
// zero-code change.
const repo = process.env.GITHUB_REPOSITORY?.split('/')[1]

export default defineConfig({
  base: repo ? `/${repo}/` : '/',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
})
