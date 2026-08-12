import { useState, type FormEvent } from 'react'
import { messageOf } from '@/lib/errors'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { Button, Input } from '@/design-system'
import { AuthCard, FormError } from '../AuthCard'
import { signIn } from '../api'

export function LoginPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await signIn(email, password)
      const from = (location.state as { from?: { pathname: string; search?: string } } | null)?.from
      navigate(from ? { pathname: from.pathname, search: from.search } : '/', { replace: true })
    } catch (err) {
      setError(messageOf(err, 'Sign in failed.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthCard title="Sign in" subtitle="The practice portal for your clients' books">
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
        <Input
          label="Password"
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <Button type="submit" disabled={busy} fullWidth>
          {busy ? 'Signing in' : 'Sign in'}
        </Button>
        <div style={{ display: 'flex', justifyContent: 'space-between', font: 'var(--type-body-sm)' }}>
          <Link to="/reset-password">Forgot password</Link>
          <Link to="/signup">Create an account</Link>
        </div>
      </form>
    </AuthCard>
  )
}
