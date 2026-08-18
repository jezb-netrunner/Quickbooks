import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Checkbox, Dialog, IconButton, Input, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { Account, Contact, DocumentRow, Item, OpenItemRow } from '@/lib/database.types'
import { AttachmentsSection } from '@/features/attachments/AttachmentsSection'
import { useIsFirmAdmin } from '@/features/clients/hooks'
import { useSubmitDocument } from '@/features/review/hooks'
import { useTaxCodes } from '@/features/tax/hooks'
import { useItems } from '@/features/inventory/hooks'
import type { TaxCodeWithRate } from '@/features/tax/api'
import { docLabel, openItemRef, type DocTypeConfig } from './docTypes'
import { localToday } from '@/lib/dates'
import {
  useDeleteDocument,
  useDocumentDetail,
  useIssueDocument,
  useOpenItems,
  useSaveDocument,
  useVoidDocument,
} from './hooks'

interface EditableLine {
  item_id: string
  qty: string
  account_id: string
  description: string
  amount: string
  tax_code_id: string
}

interface EditableApplication {
  target_document_id: string
  label: string
  open: number
  gross: number
  net: number
  amount: string
}

// Half-away-from-zero at 2 decimals, immune to float dust (102.50 * 0.01 =
// 1.0250000000000001 must round to 1.03, matching Postgres numeric round()).
function round2(x: number): number {
  return Math.round(Number((x * 100).toFixed(4))) / 100
}

// Client-side preview of the engine's per-line VAT math (the engine recomputes
// authoritatively at issue, by document date). Inclusive: net = amount/(1+r).
function lineTax(amount: number, rate: number | null, inclusive: boolean) {
  if (!rate || amount <= 0) return { net: amount, tax: 0 }
  if (inclusive) {
    const net = round2(amount / (1 + rate))
    return { net, tax: round2(amount - net) }
  }
  return { net: amount, tax: round2(amount * rate) }
}

export function DocumentDialog(props: {
  clientId: string
  config: DocTypeConfig
  contacts: Contact[]
  accounts: Account[]
  document: DocumentRow | null
  requireApproval: boolean
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const { data: detail, isPending } = useDocumentDetail(props.clientId, props.document?.id ?? null)
  const { data: taxCodes } = useTaxCodes(props.clientId)
  // Payments must not render before open items resolve: the form's replace-set
  // save would otherwise serialize an empty application list and silently
  // delete a saved draft's applications.
  const { data: openItems } = useOpenItems(
    props.clientId,
    props.config.appliesTo ?? 'receivable',
    localToday(),
  )
  const { data: items } = useItems(props.clientId)
  if (
    (props.document && isPending) ||
    taxCodes === undefined ||
    items === undefined ||
    (props.config.appliesTo !== null && openItems === undefined)
  )
    return null
  return (
    <DocumentForm
      {...props}
      taxCodes={taxCodes}
      items={items}
      openItems={openItems ?? []}
      detail={detail ?? { lines: [], applications: [] }}
    />
  )
}

function DocumentForm({
  clientId,
  config,
  contacts,
  accounts,
  taxCodes,
  items,
  openItems,
  document: doc,
  requireApproval,
  detail,
  onClose,
  onDone,
}: {
  clientId: string
  config: DocTypeConfig
  contacts: Contact[]
  accounts: Account[]
  taxCodes: TaxCodeWithRate[]
  items: Item[]
  openItems: OpenItemRow[]
  document: DocumentRow | null
  requireApproval: boolean
  detail: {
    lines: {
      account_id: string
      description: string
      amount: string
      tax_code_id: string | null
      item_id: string | null
      qty: string | null
    }[]
    applications: { target_document_id: string; amount: string }[]
  }
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const isIssued = doc !== null && doc.status !== 'draft'
  const isSubmitted = doc?.status === 'submitted'
  const isAdmin = useIsFirmAdmin()
  // Same shape as the journal: the database gate is the enforcement, this
  // only swaps the primary action for preparers under the approval regime.
  const mustSubmit = requireApproval && !isAdmin
  const save = useSaveDocument(clientId, config.type)
  const remove = useDeleteDocument(clientId)
  const issue = useIssueDocument(clientId)
  const voidDoc = useVoidDocument(clientId)
  const submitDoc = useSubmitDocument(clientId)

  const today = localToday()
  const [docDate, setDocDate] = useState(doc?.doc_date ?? today)
  const [dueDate, setDueDate] = useState(doc?.due_date ?? '')
  const [contactId, setContactId] = useState(doc?.contact_id ?? '')
  const [bankAccountId, setBankAccountId] = useState(doc?.bank_account_id ?? '')
  const [memo, setMemo] = useState(doc?.memo ?? '')
  const [inclusive, setInclusive] = useState(doc?.amounts_include_tax ?? false)
  const [settleCash, setSettleCash] = useState(
    config.hasSettlement && doc?.bank_account_id != null,
  )
  const [whtCodeId, setWhtCodeId] = useState(doc?.wht_tax_code_id ?? '')
  const [whtBase, setWhtBase] = useState(doc?.wht_base != null ? String(doc.wht_base) : '')
  // The base auto-derives from the applied documents' net-of-VAT until the
  // preparer types their own (a stored draft base counts as typed).
  const [whtBaseTouched, setWhtBaseTouched] = useState(doc?.wht_base != null)
  // P3-01: after the first successful save, retries must UPDATE this draft —
  // the doc prop never changes, so track the server-assigned id ourselves.
  // Without this, a failed issue left doc null and the next click inserted
  // (and issued) a second copy of the same document.
  const [savedId, setSavedId] = useState<string | null>(doc?.id ?? null)
  // Default a new line to the standard 12% VAT for VAT-registered clients, so a
  // VAT invoice/bill applies output/input VAT without hunting for the per-line
  // picker. Empty for non-VAT clients and doc types without line VAT (the find
  // returns nothing), and existing saved lines keep whatever was stored.
  const defaultLineTaxCodeId = config.lineTaxKind
    ? (taxCodes.find(
        (t) => t.active && t.kind === config.lineTaxKind && t.vat_class === 'taxable',
      )?.id ?? '')
    : ''
  const blankLine = (): EditableLine => ({
    item_id: '',
    qty: '',
    account_id: '',
    description: '',
    amount: '',
    tax_code_id: defaultLineTaxCodeId,
  })
  const [lines, setLines] = useState<EditableLine[]>(
    detail.lines.length > 0
      ? detail.lines.map((l) => ({
          item_id: l.item_id ?? '',
          qty: l.qty != null ? String(Number(l.qty)) : '',
          account_id: l.account_id,
          description: l.description,
          amount: String(l.amount),
          tax_code_id: l.tax_code_id ?? '',
        }))
      : config.hasLines
        ? [blankLine()]
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
  // A summary/header account (one that owns child accounts) is never a posting
  // target, so it must not appear in any account picker. parent_id is the
  // intended signal but the COA seed populates it inconsistently, so also treat
  // an account whose code owns `${code}-NN` children as a header.
  const headerAccountIds = useMemo(() => {
    const ids = new Set<string>()
    for (const a of accounts) {
      const ownsChildren = accounts.some(
        (o) => o.id !== a.id && (o.parent_id === a.id || o.code.startsWith(`${a.code}-`)),
      )
      if (ownsChildren) ids.add(a.id)
    }
    return ids
  }, [accounts])
  // Cash side of receipts/disbursements: postable cash accounts only — never the
  // "Cash and cash equivalents" header that the old code.startsWith('1000')
  // sweep wrongly included (P: cash picker showed the parent rollup).
  const bankAccounts = useMemo(
    () =>
      accounts.filter(
        (a) => !a.archived_at && a.code.startsWith('1000') && !headerAccountIds.has(a.id),
      ),
    [accounts, headerAccountIds],
  )
  const taxAccountCodes = useMemo(() => new Set(taxCodes.map((t) => t.account_code)), [taxCodes])
  // Only the account types that make sense for this document's lines, and
  // never the AR/AP control accounts or tax posting accounts — the engine
  // posts those sides itself. A saved draft may still reference an account
  // outside the filter; keep such accounts listed so the row stays legible.
  const referenced = useMemo(() => new Set(detail.lines.map((l) => l.account_id)), [detail.lines])
  const lineAccounts = useMemo(
    () =>
      accounts.filter(
        (a) =>
          referenced.has(a.id) ||
          (config.hasItems && a.code === '1200' && !a.archived_at) ||
          (!a.archived_at &&
            config.lineAccountTypes.includes(a.account_type) &&
            a.code !== '1100' &&
            a.code !== '2000' &&
            a.code !== '1200' &&
            !taxAccountCodes.has(a.code) &&
            !headerAccountIds.has(a.id)),
      ),
    [accounts, config.hasItems, config.lineAccountTypes, referenced, taxAccountCodes, headerAccountIds],
  )
  const lineTaxCodes = useMemo(
    () => taxCodes.filter((t) => t.active && t.kind === config.lineTaxKind),
    [taxCodes, config.lineTaxKind],
  )
  const whtCodes = useMemo(
    () => taxCodes.filter((t) => t.active && t.kind === config.whtKind),
    [taxCodes, config.whtKind],
  )
  const rateOf = useMemo(() => {
    const m = new Map<string, number | null>()
    for (const t of taxCodes) m.set(t.id, t.currentRate)
    return m
  }, [taxCodes])
  const activeItems = useMemo(() => items.filter((i) => !i.archived_at), [items])
  const itemById = useMemo(() => new Map(items.map((i) => [i.id, i])), [items])
  // Purchases post item lines to the 1200 Inventory control account.
  const inventoryAccount = useMemo(() => accounts.find((a) => a.code === '1200'), [accounts])

  // Picking an item wires the line: account (income for sales, 1200 for
  // purchases), default amount from qty x default price/cost.
  function applyItem(i: number, itemId: string, qtyStr: string) {
    const item = itemId ? itemById.get(itemId) : undefined
    const qty = Number(qtyStr) || 0
    const price = config.type === 'invoice' ? item?.sales_price : item?.purchase_cost
    setLines((prev) =>
      prev.map((l, idx) => {
        if (idx !== i) return l
        const next = { ...l, item_id: itemId, qty: qtyStr }
        if (item) {
          next.account_id =
            config.type === 'purchase'
              ? (inventoryAccount?.id ?? l.account_id)
              : (item.income_account_id ?? l.account_id)
          if (!next.description) next.description = item.name
          if (qty > 0 && price != null) next.amount = String(round2(qty * Number(price)))
        }
        return next
      }),
    )
  }

  // Open items of the chosen contact, for payments (fetched by the wrapper
  // before this form mounts — see DocumentDialog).
  const savedApplied = useMemo(
    () => new Map(detail.applications.map((a) => [a.target_document_id, Number(a.amount)])),
    [detail.applications],
  )
  const [applications, setApplications] = useState<EditableApplication[] | null>(null)
  const appRows: EditableApplication[] = useMemo(() => {
    if (applications) return applications
    if (!config.appliesTo) return []
    return openItems
      .filter((o) => o.contact_id === contactId)
      .map((o) => ({
        target_document_id: o.document_id,
        label: `${openItemRef(o.doc_type, o.doc_no)} · ${o.doc_date}`,
        // Draft applications never count toward open_items, so the balance
        // shown is the true headroom even while re-editing this draft.
        open: Number(o.balance),
        gross: Number(o.total),
        net: Number(o.net),
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

  // Only lines toDraft() will actually keep count toward totals and gating —
  // an amount with no account chosen must not inflate the total or enable
  // issuing a smaller document than the screen shows.
  const completeLines = useMemo(
    () =>
      lines.filter(
        (l) => l.account_id && Number(l.amount) > 0 && (!l.item_id || Number(l.qty) > 0),
      ),
    [lines],
  )
  const lineTotal = completeLines.reduce((s, l) => s + Number(l.amount), 0)
  const hasIncompleteLine = lines.some(
    (l) =>
      (Number(l.amount) > 0 && !l.account_id) ||
      (l.item_id !== '' && !(Number(l.qty) > 0)) ||
      (l.item_id !== '' && !(Number(l.amount) > 0)),
  )
  const appTotal = appRows.reduce((s, a) => s + (Number(a.amount) || 0), 0)

  // Live tax preview mirroring the engine's math.
  const taxPreview = useMemo(() => {
    let net = 0
    let vat = 0
    for (const l of completeLines) {
      const amount = Number(l.amount)
      const r = l.tax_code_id ? (rateOf.get(l.tax_code_id) ?? null) : null
      const t = lineTax(amount, r, inclusive)
      net += t.net
      vat += t.tax
    }
    return { net: round2(net), vat: round2(vat) }
  }, [completeLines, rateOf, inclusive])
  // T-04: decompose what this payment settles. Each application is gross;
  // its net/VAT split pro-rates by the target document's frozen shares —
  // mirroring the engine's P3-03 ceiling (round per application, then sum).
  const appliedSplit = useMemo(() => {
    let net = 0
    let vatPart = 0
    for (const a of appRows) {
      const amt = Number(a.amount)
      if (!(amt > 0) || !(a.gross > 0)) continue
      const n = round2((amt * a.net) / a.gross)
      net += n
      vatPart += round2(amt - n)
    }
    return { net: round2(net), vat: round2(vatPart) }
  }, [appRows])
  const suggestedBase = appliedSplit.net
  const effectiveWhtBase = whtBaseTouched ? whtBase : suggestedBase > 0 ? String(suggestedBase) : ''
  const whtRate = whtCodeId ? (rateOf.get(whtCodeId) ?? null) : null
  const whtAmount =
    whtCodeId && whtRate && Number(effectiveWhtBase) > 0 ? round2(Number(effectiveWhtBase) * whtRate) : 0
  const docGross = taxPreview.net + taxPreview.vat
  const grandTotal =
    config.appliesTo === null ? docGross : appTotal + docGross - whtAmount
  const issueGate =
    (config.appliesTo === null ? lineTotal : appTotal + lineTotal) > 0 &&
    !hasIncompleteLine &&
    !(config.hasBank && !bankAccountId)

  function toDraft() {
    return {
      docDate,
      dueDate: config.hasDueDate && dueDate ? dueDate : null,
      contactId,
      bankAccountId:
        (config.hasBank || (config.hasSettlement && settleCash)) && bankAccountId
          ? bankAccountId
          : null,
      memo: memo.trim(),
      amountsIncludeTax: inclusive,
      // Code and base save as a pair (the documents_wht_pair_check demands
      // it): a code with no positive base serializes as no withholding.
      whtTaxCodeId:
        config.whtKind && whtCodeId && Number(effectiveWhtBase) > 0 ? whtCodeId : null,
      whtBase:
        config.whtKind && whtCodeId && Number(effectiveWhtBase) > 0
          ? Number(effectiveWhtBase)
          : null,
      lines: lines
        .filter((l) => l.account_id && Number(l.amount) > 0 && (!l.item_id || Number(l.qty) > 0))
        .map((l) => ({
          account_id: l.account_id,
          description: l.description.trim(),
          amount: Number(l.amount),
          tax_code_id: l.tax_code_id || null,
          item_id: l.item_id || null,
          qty: l.item_id && Number(l.qty) > 0 ? Number(l.qty) : null,
        })),
      applications: appRows
        .filter((a) => Number(a.amount) > 0)
        .map((a) => ({ target_document_id: a.target_document_id, amount: Number(a.amount) })),
    }
  }

  const busy = save.isPending || remove.isPending || issue.isPending || voidDoc.isPending || submitDoc.isPending
  const title = doc ? `${docLabel(config, doc.doc_no)} · ${doc.status}` : `New ${config.noun}`
  const showTaxColumn = config.lineTaxKind !== null && lineTaxCodes.length > 0
  const showItemColumn = config.hasItems && activeItems.length > 0
  const lineGrid = showItemColumn
    ? showTaxColumn
      ? 'minmax(0, 1fr) 64px minmax(0, 1fr) minmax(0, 0.9fr) 100px 34px'
      : 'minmax(0, 1fr) 64px minmax(0, 1fr) minmax(0, 0.9fr) 110px 34px'
    : showTaxColumn
      ? 'minmax(0, 1fr) minmax(0, 0.8fr) minmax(0, 0.7fr) 100px 34px'
      : 'minmax(0, 1fr) minmax(0, 1fr) 110px 34px'

  return (
    <Dialog
      open
      onClose={onClose}
      width={showItemColumn ? 780 : showTaxColumn ? 720 : 640}
      title={title}
      description={
        isSubmitted
          ? 'Locked while under review — a firm admin approves or returns it from the Approvals page.'
          : isIssued
            ? 'Issued documents are immutable. Corrections go through void, which posts a reversing entry.'
            : mustSubmit
              ? 'Drafts are editable; this client requires review, so submitting sends the document to a firm admin.'
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
                  { documentId: savedId, draft: toDraft() },
                  {
                    onSuccess: (id) => { setSavedId(id); onDone('Draft saved'); onClose() },
                    onError: (err) => setError(messageOf(err, 'Could not save the draft.')),
                  },
                )
              }
            >
              Save draft
            </Button>
            <Button
              variant="accent"
              disabled={busy || !contactId || !issueGate || (config.hasSettlement && settleCash && !bankAccountId)}
              onClick={() =>
                save.mutate(
                  { documentId: savedId, draft: toDraft() },
                  {
                    onSuccess: (id) => {
                      setSavedId(id)
                      return mustSubmit
                        ? submitDoc.mutate(id, {
                            onSuccess: () => { onDone('Submitted for review'); onClose() },
                            onError: (err) => setError(messageOf(err, 'Could not submit the document.')),
                          })
                        : issue.mutate(id, {
                            onSuccess: (no) => { onDone(`Issued as ${config.prefix}-${no}`); onClose() },
                            onError: (err) => setError(messageOf(err, 'Could not issue the document.')),
                          })
                    },
                    onError: (err) => setError(messageOf(err, 'Could not save the draft.')),
                  },
                )
              }
            >
              {busy ? 'Working' : mustSubmit ? 'Save and submit' : 'Save and issue'}
            </Button>
          </>
        )
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        {doc?.status === 'draft' && doc.review_note !== '' && (
          <div style={{ padding: '10px 12px', background: 'var(--sand-100)', borderRadius: 'var(--radius-md)' }}>
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--clay-600)' }}>
              Returned for changes: {doc.review_note}
            </p>
          </div>
        )}
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
        {config.hasSettlement && (
          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
            <Select
              label="Settlement"
              options={[
                { value: 'on_account', label: config.settleOnAccountLabel },
                { value: 'cash', label: config.settleCashLabel },
              ]}
              value={settleCash ? 'cash' : 'on_account'}
              disabled={isIssued}
              onChange={(e) => {
                const cash = e.target.value === 'cash'
                setSettleCash(cash)
                if (!cash) setBankAccountId('')
              }}
            />
            {settleCash && (
              <Select
                label={config.contactSide === 'customer' ? 'Deposit to' : 'Paid from'}
                placeholder="Cash or bank account"
                options={bankAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
                value={bankAccountId}
                disabled={isIssued}
                onChange={(e) => setBankAccountId(e.target.value)}
              />
            )}
          </div>
        )}
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
              Apply to open {config.appliesTo === 'receivable' ? 'invoices' : 'bills and purchases'}
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
              <>
                <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 110px 110px 130px', gap: 8 }}>
                  <span />
                  <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)', textAlign: 'right' }}>Open (gross)</span>
                  <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)', textAlign: 'right' }}>Net of VAT</span>
                  <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)', textAlign: 'right' }}>Apply</span>
                </div>
                {appRows.map((a, i) => (
                  <div key={a.target_document_id} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 110px 110px 130px', gap: 8, alignItems: 'center' }}>
                    <span style={{ font: '400 13px/1.3 var(--font-mono)' }}>{a.label}</span>
                    <span style={{ textAlign: 'right' }}>
                      <Amount value={a.open} muted />
                    </span>
                    <span style={{ textAlign: 'right' }}>
                      <Amount value={a.gross > 0 ? round2((a.open * a.net) / a.gross) : a.open} muted />
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
                ))}
              </>
            )}
          </div>
        )}

        {config.whtKind && whtCodes.length > 0 && (
          <div style={{ display: 'grid', gap: 8 }}>
            <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
              {config.whtKind === 'withholding_sales'
                ? 'Tax the customer withheld (their 2307)'
                : 'Tax withheld from the vendor'}
            </span>
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 130px 110px', gap: 8, alignItems: 'end' }}>
              <Select
                label="Withholding code"
                placeholder="None"
                options={whtCodes.map((t) => ({
                  value: t.id,
                  label: `${t.name}${t.currentRate != null ? ` (${(t.currentRate * 100).toFixed(t.currentRate * 100 % 1 === 0 ? 0 : 2)}%)` : ''}`,
                }))}
                value={whtCodeId}
                disabled={isIssued}
                onChange={(e) => setWhtCodeId(e.target.value)}
              />
              <Input
                label="Base (net of VAT)"
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={effectiveWhtBase}
                disabled={isIssued || !whtCodeId}
                onChange={(e) => {
                  setWhtBaseTouched(true)
                  setWhtBase(e.target.value)
                }}
              />
              <div style={{ textAlign: 'right', paddingBottom: 9 }}>
                <Amount value={whtAmount} muted />
              </div>
            </div>
            {whtCodeId && suggestedBase > 0 && whtBaseTouched && Number(whtBase) !== suggestedBase && !isIssued && (
              <button
                type="button"
                onClick={() => { setWhtBaseTouched(false); setWhtBase('') }}
                style={{ justifySelf: 'start', background: 'none', border: 'none', padding: 0, cursor: 'pointer', font: 'var(--type-label)', color: 'var(--accent-600, var(--text-secondary))', textDecoration: 'underline' }}
              >
                Use the applied net of VAT: {suggestedBase.toLocaleString('en-PH', { minimumFractionDigits: 2 })}
              </button>
            )}
          </div>
        )}

        {config.hasLines && (
          <div style={{ display: 'grid', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
                {config.lineHint || 'Lines'}
              </span>
              {showTaxColumn && (
                <Checkbox
                  label="Amounts include VAT"
                  checked={inclusive}
                  disabled={isIssued}
                  onChange={(e) => setInclusive(e.target.checked)}
                />
              )}
            </div>
            {lines.map((line, i) => (
              <div key={i} style={{ display: 'grid', gridTemplateColumns: lineGrid, gap: 8, alignItems: 'center' }}>
                {showItemColumn && (
                  <>
                    <Select
                      aria-label={`Line ${i + 1} item`}
                      placeholder="No item — service"
                      options={activeItems.map((it) => ({ value: it.id, label: `${it.sku} ${it.name}` }))}
                      value={line.item_id}
                      disabled={isIssued}
                      onChange={(e) => applyItem(i, e.target.value, line.qty || '1')}
                    />
                    <Input
                      aria-label={`Line ${i + 1} quantity`}
                      type="number"
                      min="0"
                      step="0.0001"
                      placeholder="Qty"
                      value={line.qty}
                      disabled={isIssued || !line.item_id}
                      onChange={(e) => applyItem(i, line.item_id, e.target.value)}
                    />
                  </>
                )}
                <Select
                  aria-label={`Line ${i + 1} account`}
                  placeholder="Account"
                  options={lineAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
                  value={line.account_id}
                  disabled={isIssued || (config.type === 'purchase' && line.item_id !== '')}
                  onChange={(e) => setLine(i, { account_id: e.target.value })}
                />
                {!showItemColumn && (
                  <Input
                    aria-label={`Line ${i + 1} description`}
                    placeholder="Description"
                    value={line.description}
                    disabled={isIssued}
                    onChange={(e) => setLine(i, { description: e.target.value })}
                  />
                )}
                {showTaxColumn && (
                  <Select
                    aria-label={`Line ${i + 1} tax`}
                    placeholder="No tax"
                    options={lineTaxCodes.map((t) => ({ value: t.id, label: t.code }))}
                    value={line.tax_code_id}
                    disabled={isIssued}
                    onChange={(e) => setLine(i, { tax_code_id: e.target.value })}
                  />
                )}
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
                {!isIssued && lines.length > 1 ? (
                  <IconButton icon="x" label={`Remove line ${i + 1}`} size={14} onClick={() => setLines((p) => p.filter((_, idx) => idx !== i))} />
                ) : (
                  <span />
                )}
              </div>
            ))}
            {!isIssued && (
              <div>
                <Button size="sm" variant="ghost" iconLeft="plus" onClick={() => setLines((p) => [...p, blankLine()])}>
                  Add line
                </Button>
              </div>
            )}
          </div>
        )}

        <div style={{ display: 'grid', gap: 6, padding: '10px 12px', background: 'var(--sand-100)', borderRadius: 'var(--radius-md)' }}>
          {showTaxColumn && taxPreview.vat > 0 && (
            <>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
                <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>Net of VAT</span>
                <Amount value={taxPreview.net} muted />
              </div>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
                <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>VAT</span>
                <Amount value={taxPreview.vat} muted />
              </div>
            </>
          )}
          {config.appliesTo !== null && appTotal > 0 && appliedSplit.vat > 0 && (
            <>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
                <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>Applied (gross)</span>
                <Amount value={appTotal} muted />
              </div>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
                <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>of which VAT</span>
                <Amount value={appliedSplit.vat} muted />
              </div>
              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
                <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>Net of VAT</span>
                <Amount value={appliedSplit.net} muted />
              </div>
            </>
          )}
          {whtAmount > 0 && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
              <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>Withheld</span>
              <Amount value={-whtAmount} muted />
            </div>
          )}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24 }}>
            <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>
              {config.hasBank || (config.hasSettlement && settleCash) ? 'Cash total' : 'Total'}
            </span>
            <Amount value={grandTotal} />
          </div>
        </div>

        {doc && (
          <AttachmentsSection clientId={clientId} target={{ documentId: doc.id }} canWrite={!isSubmitted} />
        )}
      </div>
    </Dialog>
  )
}
