// The Supabase URL and anon key are public by design — they ship in every
// Supabase SPA bundle; safety comes entirely from RLS (proven by the pgTAP
// suite). This module must never throw at import time: main.tsx calls
// readEnv() BEFORE loading the app and renders a readable setup screen when
// configuration is missing — an exception during module evaluation would be a
// blank page with the real message hidden in the console.

export interface AppEnv {
  supabaseUrl: string
  supabaseAnonKey: string
}

export type EnvResult = { ok: true; env: AppEnv } | { ok: false; missing: string[] }

export function readEnv(): EnvResult {
  const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim()
  const supabaseAnonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim()
  const missing: string[] = []
  if (!supabaseUrl) missing.push('VITE_SUPABASE_URL')
  if (!supabaseAnonKey) missing.push('VITE_SUPABASE_ANON_KEY')
  if (missing.length > 0 || !supabaseUrl || !supabaseAnonKey) return { ok: false, missing }
  return { ok: true, env: { supabaseUrl, supabaseAnonKey } }
}
