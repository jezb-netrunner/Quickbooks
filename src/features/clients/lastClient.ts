// localStorage only seeds the "/" redirect convenience. It is ALWAYS
// re-validated against the RLS-visible client list before use — never trusted.
const KEY = 'larkspur.lastClientId'

export function rememberLastClient(clientId: string) {
  try {
    localStorage.setItem(KEY, clientId)
  } catch {
    // storage unavailable (private mode) — the redirect just falls back
  }
}

export function recallLastClient(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}
