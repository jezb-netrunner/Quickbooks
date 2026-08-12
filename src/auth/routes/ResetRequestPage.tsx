import { useState, type FormEvent } from 'react'
import { messageOf } from '@/lib/errors'
import { Link } from 'react-router-dom'
import { Button, Input } from '@/design-system'
import { AuthCard, FormError } from '../AuthCard'
import { requestPasswordReset } from '../api'

export function ResetRequestPage() {
  const [email, setEmail] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await requestPasswordReset(email)
      setSent(true)
    } catch (err) {
      setError(messageOf(err, 'Request failed.'))
    } finally {
      setBusy(false)
    }
  }

  if (sent) {
    return (
      <AuthCard title="Check your inbox" subtitle={`If an account exists for ${email}, a reset link is on its way`}>
        <Link to="/login">Back to sign in</Link>
      </AuthCard>
    )
  }

  return (
    <AuthCard title="Reset your password" subtitle="We email you a link to set a new one">
      <form onSubmit={onSubmit} style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input
          label="Email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <Button type="submit" disabled={busy} fullWidth>
          {busy ? 'Sending' : 'Send reset link'}
        </Button>
        <div style={{ font: 'var(--type-body-sm)', textAlign: 'center' }}>
          <Link to="/login">Back to sign in</Link>
        </div>
      </form>
    </AuthCard>
  )
}
