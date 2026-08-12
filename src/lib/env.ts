// The Supabase URL and anon key are public by design — they ship in every
// Supabase SPA bundle; safety comes entirely from RLS (proven by the pgTAP
// suite). Fail loudly at startup if they are missing so a misconfigured deploy
// breaks on first paint instead of with cryptic fetch errors.
function required(name: string): string {
  const value = import.meta.env[name] as string | undefined
  if (!value) {
    throw new Error(
      `${name} is not set. Copy .env.example to .env.local for local development, ` +
        `or set the repository variable for deploys.`,
    )
  }
  return value
}

export const env = {
  supabaseUrl: required('VITE_SUPABASE_URL'),
  supabaseAnonKey: required('VITE_SUPABASE_ANON_KEY'),
}
