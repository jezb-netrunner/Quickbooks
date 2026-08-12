import { createClient } from '@supabase/supabase-js'
import type { Database } from './database.types'
import { readEnv } from './env'

// This module is only ever imported after main.tsx has verified readEnv().ok,
// so the throw below is a backstop, not a user-facing path.
const result = readEnv()
if (!result.ok) {
  throw new Error(`Supabase configuration missing: ${result.missing.join(', ')}`)
}
const env = result.env

// The one client instance. PKCE + detectSessionInUrl handle the email
// confirmation / password recovery links landing under the GitHub Pages
// subpath (the 404-fallback copy of index.html passes query params through).
export const supabase = createClient<Database>(env.supabaseUrl, env.supabaseAnonKey, {
  auth: {
    flowType: 'pkce',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})

// Every auth redirect derives from BASE_URL through this helper — the repo
// name never appears in source, and no redirect URL is ever hand-built.
export function authRedirectUrl(path: string): string {
  const base = import.meta.env.BASE_URL.endsWith('/')
    ? import.meta.env.BASE_URL
    : `${import.meta.env.BASE_URL}/`
  return new URL(`${base}${path.replace(/^\//, '')}`, window.location.origin).href
}
