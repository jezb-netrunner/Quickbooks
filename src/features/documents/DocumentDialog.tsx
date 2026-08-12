import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Dialog, IconButton, Input, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { Account, Contact, DocumentRow } from '@/lib/database.types'
import { docLabel, type DocTypeConfig } from './docTypes'
import {
  useDeleteDocument,
  useDocumentDetail,
  useIssueDocument,
  useOpenItems,
  useSaveDocument,
  useVoidDocument,
} from './hooks'

interface EditableLine {
  account_id: string
  description: string
  amount: string
}

interface EditableApplication {
  target_document_id: string
  label: string
  open: number
  amount: string
}

export function DocumentDialog(props: {
  clientId: string
  config: DocTypeConfig
  contacts: Contact[]
  accounts: Account[]
  document: DocumentRow | null
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const { data: detail, isPending } = useDocumentDetail(props.clientId, props.document?.id ?? null)
  if (props.document && isPending) return null
  return <DocumentForm {...props} detail={detail ?? { lines: [], applications: [] }} />
}

function DocumentForm({
  clientId,
  config,
  contacts,
  accounts,
  document: doc,
  detail,
  onClose,
  onDone,
}: {
  clientId: string
  config: DocTypeConfig
  contacts: Contact[]
  accounts: Account[]
  document: DocumentRow | null
  detail: { lines: { account_id: string; description: string; amount: string }[]; applications: { target_document_id: string; amount: string }[] }
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const isIssued = doc !== null && doc.status !== 'draft'
  const save = useSaveDocument(clientId, config.type)
  const remove = useDeleteDocument(clientId)
  const issue = useIssueDocument(clientId)
  const voidDoc = useVoidDocument(clientId)

  const today = new Date().toISOString().slice(0, 10)
  const [docDate, setDocDate] = useState(doc?.doc_date ?? today)
  const [dueDate, setDueDate] = useState(doc?.due_date ?? '')
  const [contactId, setContactId] = useState(doc?.contact_id ?? '')
  const [bankAccountId, setBankAccountId] = useState(doc?.bank_account_id ?? '')
  const [memo, setMemo] = useState(doc?.memo ?? '')
  const [lines, setLines] = useState<EditableLine[]>(
    detail.lines.length > 0
      ? detail.lines.map((l) => ({ account_id: l.account_id, description: l.description, amount: String(l.amount) }))
      : config.hasLines && config.type !== 'disbursement'
        ? [{ account_id: '', description: '', amount: '' }]
        : [],
  )
  const [error, setError] = useState<string | null>(null)

  const eligibleContacts = useMemo(
    () =>
      contacts.filter(
        (c) => !c.archived_at && (c.contact_type === 'both' || c.contact_type === config.contactSide),
      ),
    [contacts, config.contactSide],
  )
  const bankAccounts = useMemo(
    () => accounts.filter((a) => !a.archived_at && a.code.startsWith('1000')),
    [accounts],
  )
  // Only the account types that make sense for this document's lines, and
  // never the AR/AP control accounts — the engine posts those sides itself.
  // A saved draft may still reference an account outside the filter (e.g.
  // drafted before this rule); keep such accounts listed so the row stays
  // legible instead of showing an empty select.
  const referenced = useMemo(() => new Set(detail.lines.map((l) => l.account_id)), [detail.lines])
  const lineAccounts = useMemo(
    () =>
      accounts.filter(
        (a) =>
          referenced.has(a.id) ||
          (!a.archived_at &&
            config.lineAccountTypes.includes(a.account_type) &&
            a.code !== '1100' &&
            a.code !== '2000'),
      ),
    [accounts, config.lineAccountTypes, referenced],
  )

  // Open items of the chosen contact, for payments
  const { data: openItems } = useOpenItems(clientId, config.appliesTo ?? 'invoice', today)
  const savedApplied = useMemo(
    () => new Map(detail.applications.map((a) => [a.target_document_id, Number(a.amount)])),
    [detail.applications],
  )
  const [applications, setApplications] = useState<EditableApplication[] | null>(null)
  const appRows: EditableApplication[] = useMemo(() => {
    if (applications) return applications
    if (!config.appliesTo || !openItems) return []
    return openItems
      .filter((o) => o.contact_id === contactId)
      .map((o) => ({
        target_document_id: o.document_id,
        label: `${config.appliesTo === 'invoice' ? 'INV' : 'BILL'}-${o.doc_no} · ${o.doc_date}`,
        // Draft applications never count toward open_items, so the balance
        // shown is the true headroom even while re-editing this draft.
        open: Number(o.balance),
        amount: savedApplied.has(o.document_id) ? String(savedApplied.get(o.document_id)) : '',
      }))
  }, [applications, openItems, contactId, config.appliesTo, savedApplied])

  function setApp(i: number, amount: string) {
    const next = appRows.map((a, idx) => (idx === i ? { ...a, amount } : a))
    setApplications(next)
  }
  function setLine(i: number, patch: Partial<EditableLine>) {
    setLines((prev) => prev.map((l, idx) => (idx === i ? { ...l, ...patch } : l)))
  }

  const lineTotal = lines.reduce((s, l) => s + (Number(l.amount) || 0), 0)
  const appTotal = appRows.reduce((s, a) => s + (Number(a.amount) || 0), 0)
  const grandTotal = lineTotal + appTotal

  function toDraft() {
    return {
      docDate,
      dueDate: config.hasDueDate && dueDate ? dueDate : null,
      contactId,
      bankAccountId: config.hasBank && bankAccountId ? bankAccountId : null,
      memo: memo.trim(),
      lines: lines
        .filter((l) => l.account_id && Number(l.amount) > 0)
        .map((l) => ({ account_id: l.account_id, description: l.description.trim(), amount: Number(l.amount) })),
      applications: appRows
        .filter((a) => Number(a.amount) > 0)
        .map((a) => ({ target_document_id: a.target_document_id, amount: Number(a.amount) })),
    }
  }

  const busy = save.isPending || remove.isPending || issue.isPending || voidDoc.isPending
  const title = doc ? `${docLabel(config, doc.doc_no)} · ${doc.status}` : `New ${config.noun}`

  return (
    <Dialog
      open
      onClose={onClose}
      width={640}
      title={title}
      description={
        isIssued
          ? 'Issued documents are immutable. Corrections go through void, which posts a reversing entry.'
          : 'Drafts are editable; issuing posts the journal entry and assigns the number.'
      }
      footer={
        isIssued ? (
          <>
            {doc?.status === 'issued' && (
              <Button
                variant="danger"
                iconLeft="rotate-ccw"
                disabled={busy}
                onClick={() =>
                  voidDoc.mutate(
                    { id: doc.id },
                    {
                      onSuccess: () => { onDone('Voided — reversing entry posted'); onClose() },
                      onError: (err) => setError(messageOf(err, 'Could not void the document.')),
                    },
                  )
                }
              >
                Void
              </Button>
            )}
            <Button variant="ghost" onClick={onClose}>
              Close
            </Button>
          </>
        ) : (
          <>
            {doc && (
              <Button
                variant="danger"
                iconLeft="trash-2"
                disabled={busy}
                onClick={() =>
                  remove.mutate(doc.id, {
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
              disabled={busy || !contactId}
              onClick={() =>
                save.mutate(
                  { documentId: doc?.id ?? null, draft: toDraft() },
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
              disabled={busy || !contactId || grandTotal <= 0}
              onClick={() =>
                save.mutate(
                  { documentId: doc?.id ?? null, draft: toDraft() },
                  {
                    onSuccess: (id) =>
                      issue.mutate(id, {
                        onSuccess: (no) => { onDone(`Issued as ${config.prefix}-${no}`); onClose() },
                        onError: (err) => setError(messageOf(err, 'Could not issue the document.')),
                      }),
                    onError: (err) => setError(messageOf(err, 'Could not save the draft.')),
                  },
                )
              }
            >
              {busy ? 'Working' : 'Save and issue'}
            </Button>
          </>
        )
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: config.hasDueDate ? 'minmax(0, 1fr) 140px 140px' : 'minmax(0, 1fr) 170px', gap: 12 }}>
          <Select
            label={config.contactSide === 'customer' ? 'Customer' : 'Vendor'}
            placeholder={`Choose a ${config.contactSide}`}
            options={eligibleContacts.map((c) => ({ value: c.id, label: c.name }))}
            value={contactId}
            disabled={isIssued}
            onChange={(e) => { setContactId(e.target.value); setApplications(null) }}
          />
          <Input label="Date" type="date" value={docDate} disabled={isIssued} onChange={(e) => setDocDate(e.target.value)} />
          {config.hasDueDate && (
            <Input label="Due" type="date" value={dueDate} disabled={isIssued} onChange={(e) => setDueDate(e.target.value)} />
          )}
        </div>
        {config.hasBank && (
          <Select
            label="Cash or bank account"
            placeholder="Where the money moved"
            options={bankAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
            value={bankAccountId}
            disabled={isIssued}
            onChange={(e) => setBankAccountId(e.target.value)}
          />
        )}
        <Input label="Memo" value={memo} disabled={isIssued} onChange={(e) => setMemo(e.target.value)} />

        {config.appliesTo && (
          <div style={{ display: 'grid', gap: 8 }}>
            <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
              Apply to open {config.appliesTo === 'invoice' ? 'invoices' : 'bills'}
            </span>
            {!contactId ? (
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>
                Choose a {config.contactSide} to see their open items.
              </p>
            ) : appRows.length === 0 ? (
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>
                Nothing open for this {config.contactSide}.
              </p>
            ) : (
              appRows.map((a, i) => (
                <div key={a.target_document_id} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 120px 130px', gap: 8, alignItems: 'center' }}>
                  <span style={{ font: '400 13px/1.3 var(--font-mono)' }}>{a.label}</span>
                  <span style={{ textAlign: 'right' }}>
                    <Amount value={a.open} muted />
                  </span>
                  <Input
                    aria-label={`Amount for ${a.label}`}
                    type="number"
                    min="0"
                    step="0.01"
                    placeholder="0.00"
                    value={a.amount}
                    disabled={isIssued}
                    onChange={(e) => setApp(i, e.target.value)}
                  />
                </div>
              ))
            )}
          </div>
        )}

        {config.hasLines && (
          <div style={{ display: 'grid', gap: 8 }}>
            <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
              {config.lineHint || 'Lines'}
            </span>
            {lines.map((line, i) => (
              <div key={i} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr) 110px 34px', gap: 8, alignItems: 'center' }}>
                <Select
                  aria-label={`Line ${i + 1} account`}
                  placeholder="Account"
                  options={lineAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
                  value={line.account_id}
                  disabled={isIssued}
                  onChange={(e) => setLine(i, { account_id: e.target.value })}
                />
                <Input
                  aria-label={`Line ${i + 1} description`}
                  placeholder="Description"
                  value={line.description}
                  disabled={isIssued}
                  onChange={(e) => setLine(i, { description: e.target.value })}
                />
                <Input
                  aria-label={`Line ${i + 1} amount`}
                  type="number"
                  min="0"
                  step="0.01"
                  placeholder="0.00"
                  value={line.amount}
                  disabled={isIssued}
                  onChange={(e) => setLine(i, { amount: e.target.value })}
                />
                {!isIssued && lines.length > (config.type === 'disbursement' ? 0 : 1) ? (
                  <IconButton icon="x" label={`Remove line ${i + 1}`} size={14} onClick={() => setLines((p) => p.filter((_, idx) => idx !== i))} />
                ) : (
                  <span />
                )}
              </div>
            ))}
            {!isIssued && (
              <div>
                <Button size="sm" variant="ghost" iconLeft="plus" onClick={() => setLines((p) => [...p, { account_id: '', description: '', amount: '' }])}>
                  Add line
                </Button>
              </div>
            )}
          </div>
        )}

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24, padding: '10px 12px', background: 'var(--sand-100)', borderRadius: 'var(--radius-md)' }}>
          <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Total</span>
          <Amount value={grandTotal} />
        </div>
      </div>
    </Dialog>
  )
}
