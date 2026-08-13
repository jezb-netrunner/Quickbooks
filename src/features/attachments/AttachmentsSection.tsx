import { useRef, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Icon, IconButton } from '@/design-system'
import type { AttachmentRef } from './api'
import { openAttachment } from './api'
import { useAttachments, useDeleteAttachment, useUploadAttachment } from './hooks'

function formatBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  if (n >= 1024) return `${Math.round(n / 1024)} KB`
  return `${n} B`
}

// Receipts, invoices, and 2307 scans pinned to the exact document or entry
// they support. Renders inside both dialogs, only once the target row exists —
// storage paths are client-prefixed and the DB row is the source of truth.
export function AttachmentsSection({
  clientId,
  target,
  canWrite,
}: {
  clientId: string
  target: AttachmentRef
  canWrite: boolean
}) {
  const { data: attachments } = useAttachments(clientId, target)
  const upload = useUploadAttachment(clientId, target)
  const remove = useDeleteAttachment(clientId, target)
  const [error, setError] = useState<string | null>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  return (
    <div style={{ display: 'grid', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
        <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
          Attachments
        </span>
        {canWrite && (
          <>
            <input
              ref={fileRef}
              type="file"
              style={{ display: 'none' }}
              onChange={(e) => {
                const f = e.target.files?.[0]
                if (f) {
                  setError(null)
                  upload.mutate(f, {
                    onError: (err) => setError(messageOf(err, 'Upload failed.')),
                  })
                }
                e.target.value = ''
              }}
            />
            <Button size="sm" variant="ghost" iconLeft="paperclip" disabled={upload.isPending} onClick={() => fileRef.current?.click()}>
              {upload.isPending ? 'Uploading' : 'Attach file'}
            </Button>
          </>
        )}
      </div>
      {error && <p style={{ font: 'var(--type-body-sm)', color: 'var(--clay-600)' }}>{error}</p>}
      {(attachments ?? []).length === 0 ? (
        <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>
          No files yet{canWrite ? ' — attach the source document or receipt scan.' : '.'}
        </p>
      ) : (
        <div style={{ display: 'grid', gap: 4 }}>
          {(attachments ?? []).map((a) => (
            <div
              key={a.id}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                padding: '7px 10px',
                background: 'var(--sand-100)',
                borderRadius: 'var(--radius-md)',
              }}
            >
              <Icon name="paperclip" size={14} style={{ color: 'var(--text-muted)', flexShrink: 0 }} />
              <button
                type="button"
                onClick={() => {
                  setError(null)
                  openAttachment(a).catch((err) => setError(messageOf(err, 'Could not open the file.')))
                }}
                style={{
                  flex: 1,
                  minWidth: 0,
                  textAlign: 'left',
                  background: 'none',
                  border: 'none',
                  padding: 0,
                  cursor: 'pointer',
                  font: '400 13px/1.3 var(--font-sans)',
                  color: 'var(--text-primary)',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {a.filename}
              </button>
              <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)', flexShrink: 0 }}>
                {formatBytes(a.size_bytes)}
              </span>
              {canWrite && (
                <IconButton
                  icon="trash-2"
                  label={`Delete ${a.filename}`}
                  size={13}
                  disabled={remove.isPending}
                  onClick={() =>
                    remove.mutate(a, {
                      onError: (err) => setError(messageOf(err, 'Could not delete the file.')),
                    })
                  }
                />
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
