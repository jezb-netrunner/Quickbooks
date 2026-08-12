import { useState, type FormEvent } from 'react'
import { messageOf } from '@/lib/errors'
import { Link } from 'react-router-dom'
import { Button, Input } from '@/design-system'
import { AuthCard, FormError } from '../AuthCard'
import { signUp } from '../api'

export function SignupPage() {
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await signUp(email, password, fullName.trim())
      setSent(true)
    } catch (err) {
      setError(messageOf(err, 'Sign up failed.'))
    } finally {
      setBusy(false)
    }
  }

  if (sent) {
    return (
      <AuthCard title="Confirm your email" subtitle={`We sent a confirmation link to ${email}`}>
        <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
          Open the link to activate your account, then sign in. You need a confirmed email before a
          firm can be created or you can be added to one.
        </p>
        <div style={{ marginTop: 14 }}>
          <Link to="/login">Back to sign in</Link>
        </div>
      </AuthCard>
    )
  }

  return (
    <AuthCard title="Create an account" subtitle="Then create your firm or ask an admin to add you">
      <form onSubmit={onSubmit} style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input
          label="Full name"
          autoComplete="name"
          required
          value={fullName}
          onChange={(e) => setFullName(e.target.value)}
        />
        <Input
          label="Email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <Input
          label="Password"
          type="password"
          autoComplete="new-password"
          required
          minLength={10}
          hint="At least 10 characters"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <Button type="submit" disabled={busy} fullWidth>
          {busy ? 'Creating account' : 'Create account'}
        </Button>
        <div style={{ font: 'var(--type-body-sm)', textAlign: 'center' }}>
          <Link to="/login">Already have an account? Sign in</Link>
        </div>
      </form>
    </AuthCard>
  )
}
