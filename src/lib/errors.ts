// Supabase errors (PostgrestError, AuthError) are not always Error instances
// depending on the code path, so `err instanceof Error` can silently swallow
// the real message and show a useless fallback. Read .message off anything
// that has one.
export function messageOf(err: unknown, fallback: string): string {
  if (
    err &&
    typeof err === 'object' &&
    'message' in err &&
    typeof (err as { message: unknown }).message === 'string' &&
    (err as { message: string }).message.length > 0
  ) {
    return (err as { message: string }).message
  }
  return fallback
}
