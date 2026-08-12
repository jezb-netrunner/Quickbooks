import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button, Input } from '@/design-system'
import { AuthCard, FormError } from '../AuthCard'
import { updatePassword } from '../api'

// Landing page for the password-recovery email link. supabase-js consumes the
// recovery code from the URL (detectSessionInUrl) and signs the user in with a
// short-lived session; this form sets the new password.
export function UpdatePasswordPage() {
  const navigate = useNavigate()
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await updatePassword(password)
      navigate('/', { replace: true })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not update the password.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthCard title="Set a new password">
      <form onSubmit={onSubmit} style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input
          label="New password"
          type="password"
          autoComplete="new-password"
          required
          minLength={10}
          hint="At least 10 characters"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <Button type="submit" disabled={busy} fullWidth>
          {busy ? 'Saving' : 'Save password'}
        </Button>
      </form>
    </AuthCard>
  )
}
