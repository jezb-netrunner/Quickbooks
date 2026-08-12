import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Dialog, IconButton, Input, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import { useEntryLines, useDeleteDraft, usePostEntry, useReverseEntry, useSaveDraft } from './hooks'
import type { Account, JournalEntry } from '@/lib/database.types'

interface EditableLine {
  account_id: string
  debit: string
  credit: string
}

const EMPTY: EditableLine = { account_id: '', debit: '', credit: '' }

// Wrapper: for an existing entry the saved lines load first, then the form
// mounts with them as initial state — no effect-driven state sync.
export function EntryDialog(props: {
  clientId: string
  accounts: Account[]
  entry: JournalEntry | null
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const { data: savedLines, isPending } = useEntryLines(props.clientId, props.entry?.id ?? null)
  if (props.entry && isPending) return null
  const initialLines: EditableLine[] =
    savedLines && savedLines.length > 0
      ? savedLines.map((l) => ({
          account_id: l.account_id,
          debit: Number(l.debit) > 0 ? String(l.debit) : '',
          credit: Number(l.credit) > 0 ? String(l.credit) : '',
        }))
      : [{ ...EMPTY }, { ...EMPTY }]
  return <EntryForm {...props} initialLines={initialLines} />
}

function EntryForm({
  clientId,
  accounts,
  entry, // null = new draft
  initialLines,
  onClose,
  onDone,
}: {
  clientId: string
  accounts: Account[]
  entry: JournalEntry | null
  initialLines: EditableLine[]
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const isPosted = entry?.status === 'posted'
  const saveDraft = useSaveDraft(clientId)
  const deleteDraft = useDeleteDraft(clientId)
  const postEntry = usePostEntry(clientId)
  const reverseEntry = useReverseEntry(clientId)

  const [entryDate, setEntryDate] = useState(entry?.entry_date ?? new Date().toISOString().slice(0, 10))
  const [memo, setMemo] = useState(entry?.memo ?? '')
  const [lines, setLines] = useState<EditableLine[]>(initialLines)
  const [error, setError] = useState<string | null>(null)

  const activeAccounts = useMemo(() => accounts.filter((a) => !a.archived_at), [accounts])
  const accountName = useMemo(() => new Map(accounts.map((a) => [a.id, `${a.code} ${a.name}`])), [accounts])

  const totals = useMemo(() => {
    const debit = lines.reduce((s, l) => s + (Number(l.debit) || 0), 0)
    const credit = lines.reduce((s, l) => s + (Number(l.credit) || 0), 0)
    return { debit, credit, balanced: Math.abs(debit - credit) < 0.005 && debit > 0 }
  }, [lines])

  function toDraftInput() {
    return {
      entryDate,
      memo: memo.trim(),
      lines: lines
        .filter((l) => l.account_id && (Number(l.debit) > 0 || Number(l.credit) > 0))
        .map((l) => ({
          account_id: l.account_id,
          debit: Number(l.debit) || 0,
          credit: Number(l.credit) || 0,
        })),
    }
  }

  function setLine(i: number, patch: Partial<EditableLine>) {
    setLines((prev) => prev.map((l, idx) => (idx === i ? { ...l, ...patch } : l)))
  }

  const busy = saveDraft.isPending || postEntry.isPending || deleteDraft.isPending || reverseEntry.isPending

  const title = entry
    ? entry.status === 'posted'
      ? `JE-${entry.entry_no} · posted`
      : 'Edit draft entry'
    : 'New journal entry'

  return (
    <Dialog
      open
      onClose={onClose}
      width={640}
      title={title}
      description={
        isPosted
          ? 'Posted entries are immutable. Corrections go through a reversing entry.'
          : 'Drafts are editable; posting locks the entry and assigns its number.'
      }
      footer={
        isPosted ? (
          <>
            {entry?.reversed_by === null && entry.source_type !== 'reversal' && (
              <Button
                variant="danger"
                iconLeft="rotate-ccw"
                disabled={busy}
                onClick={() =>
                  reverseEntry.mutate(
                    { entryId: entry.id },
                    {
                      onSuccess: () => { onDone('Reversing entry posted'); onClose() },
                      onError: (err) => setError(messageOf(err, 'Could not reverse the entry.')),
                    },
                  )
                }
              >
                Reverse entry
              </Button>
            )}
            <Button variant="ghost" onClick={onClose}>
              Close
            </Button>
          </>
        ) : (
          <>
            {entry && (
              <Button
                variant="danger"
                iconLeft="trash-2"
                disabled={busy}
                onClick={() =>
                  deleteDraft.mutate(entry.id, {
                    onSuccess: () => { onDone('Draft deleted'); onClose() },
                    onError: (err) => setError(messageOf(err, 'Could not delete the draft.')),
                  })
                }
              >
                Delete draft
              </Button>
            )}
            <Button
              variant="secondary"
              disabled={busy}
              onClick={() =>
                saveDraft.mutate(
                  { entryId: entry?.id ?? null, draft: toDraftInput() },
                  {
                    onSuccess: () => { onDone('Draft saved'); onClose() },
                    onError: (err) => setError(messageOf(err, 'Could not save the draft.')),
                  },
                )
              }
            >
              Save draft
            </Button>
            <Button
              variant="accent"
              disabled={busy || !totals.balanced}
              onClick={() =>
                saveDraft.mutate(
                  { entryId: entry?.id ?? null, draft: toDraftInput() },
                  {
                    onSuccess: (id) =>
                      postEntry.mutate(id, {
                        onSuccess: (no) => { onDone(`Posted as JE-${no}`); onClose() },
                        onError: (err) => setError(messageOf(err, 'Could not post the entry.')),
                      }),
                    onError: (err) => setError(messageOf(err, 'Could not save the draft.')),
                  },
                )
              }
            >
              {busy ? 'Working' : 'Save and post'}
            </Button>
          </>
        )
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: '160px minmax(0, 1fr)', gap: 12 }}>
          <Input
            label="Date"
            type="date"
            value={entryDate}
            disabled={isPosted}
            onChange={(e) => setEntryDate(e.target.value)}
          />
          <Input
            label="Memo"
            placeholder="What is this entry for?"
            value={memo}
            disabled={isPosted}
            onChange={(e) => setMemo(e.target.value)}
          />
        </div>

        <div style={{ display: 'grid', gap: 8 }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'minmax(0, 1fr) 110px 110px 34px',
              gap: 8,
              font: 'var(--type-overline)',
              letterSpacing: 'var(--tracking-caps)',
              textTransform: 'uppercase',
              color: 'var(--text-muted)',
              padding: '0 2px',
            }}
          >
            <span>Account</span>
            <span style={{ textAlign: 'right' }}>Debit</span>
            <span style={{ textAlign: 'right' }}>Credit</span>
            <span />
          </div>
          {lines.map((line, i) => (
            <div key={i} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 110px 110px 34px', gap: 8, alignItems: 'center' }}>
              {isPosted ? (
                <span style={{ font: '400 13px/1.3 var(--font-sans)' }}>
                  {accountName.get(line.account_id) ?? '—'}
                </span>
              ) : (
                <Select
                  aria-label={`Line ${i + 1} account`}
                  placeholder="Choose an account"
                  options={activeAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
                  value={line.account_id}
                  onChange={(e) => setLine(i, { account_id: e.target.value })}
                />
              )}
              <Input
                aria-label={`Line ${i + 1} debit`}
                type="number"
                min="0"
                step="0.01"
                style={{ textAlign: 'right' }}
                value={line.debit}
                disabled={isPosted}
                onChange={(e) => setLine(i, { debit: e.target.value, credit: e.target.value ? '' : line.credit })}
              />
              <Input
                aria-label={`Line ${i + 1} credit`}
                type="number"
                min="0"
                step="0.01"
                style={{ textAlign: 'right' }}
                value={line.credit}
                disabled={isPosted}
                onChange={(e) => setLine(i, { credit: e.target.value, debit: e.target.value ? '' : line.debit })}
              />
              {!isPosted && lines.length > 2 ? (
                <IconButton
                  icon="x"
                  label={`Remove line ${i + 1}`}
                  size={14}
                  onClick={() => setLines((prev) => prev.filter((_, idx) => idx !== i))}
                />
              ) : (
                <span />
              )}
            </div>
          ))}
          {!isPosted && (
            <div>
              <Button size="sm" variant="ghost" iconLeft="plus" onClick={() => setLines((p) => [...p, { ...EMPTY }])}>
                Add line
              </Button>
            </div>
          )}
        </div>

        <div
          style={{
            display: 'flex',
            justifyContent: 'flex-end',
            gap: 24,
            padding: '10px 12px',
            background: totals.balanced ? 'var(--teal-100)' : 'var(--sand-100)',
            borderRadius: 'var(--radius-md)',
          }}
        >
          <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>
            {totals.balanced
              ? 'Balanced'
              : `Out of balance by ${Math.abs(totals.debit - totals.credit).toFixed(2)}`}
          </span>
          <Amount value={totals.debit} />
          <Amount value={totals.credit} />
        </div>
      </div>
    </Dialog>
  )
}
