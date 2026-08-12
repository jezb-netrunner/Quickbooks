import { useState, type FormEvent } from 'react'
import { messageOf } from '@/lib/errors'
import { useNavigate } from 'react-router-dom'
import { Button, Input } from '@/design-system'
import { AuthCard, FormError } from '@/auth/AuthCard'
import { useCreateFirm } from '../hooks'

export function CreateFirmPage() {
  const navigate = useNavigate()
  const createFirm = useCreateFirm()
  const [name, setName] = useState('')
  const [error, setError] = useState<string | null>(null)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    try {
      await createFirm.mutateAsync(name.trim())
      navigate('/firm', { replace: true })
    } catch (err) {
      setError(messageOf(err, 'Could not create the firm.'))
    }
  }

  return (
    <AuthCard title="Create your firm" subtitle="One firm holds all your client companies">
      <form onSubmit={onSubmit} style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input
          label="Firm name"
          placeholder="Dela Cruz & Co, CPAs"
          required
          maxLength={120}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <Button type="submit" disabled={createFirm.isPending} fullWidth>
          {createFirm.isPending ? 'Creating' : 'Create firm'}
        </Button>
      </form>
    </AuthCard>
  )
}
