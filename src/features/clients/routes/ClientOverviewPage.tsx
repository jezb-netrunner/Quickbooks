import { Badge, Card } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from './ClientLayout'

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
]

function Fact({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, padding: '10px 0', borderBottom: '1px solid var(--border-subtle)' }}>
      <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>{label}</span>
      <span style={{ font: '500 13px/1.3 var(--font-mono)', color: 'var(--text-primary)', textAlign: 'right' }}>{value}</span>
    </div>
  )
}

export function ClientOverviewPage() {
  const client = useActiveClient()
  return (
    <>
      <TopBar
        title={client.name}
        subtitle={client.archived_at ? 'Archived — the books are read-only' : 'Client overview'}
      />
      <PageBody>
        {client.archived_at && (
          <div>
            <Badge tone="warning" dot>
              Archived
            </Badge>
          </div>
        )}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16, alignItems: 'start' }}>
          <Card title="Company profile" subtitle="Set up in client settings">
            <div>
              <Fact label="Client code" value={client.code ?? '—'} />
              <Fact label="TIN" value={client.tin ?? '—'} />
              <Fact label="Reporting basis" value={client.reporting_basis} />
              <Fact label="Fiscal year ends" value={MONTHS[client.fiscal_year_end_month - 1]} />
              <Fact label="Functional currency" value={client.functional_currency} />
            </div>
          </Card>
          <Card title="The books" subtitle="Coming with the next phase" tone="sunken">
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              Phase 2 adds the chart of accounts, accounting periods, and the journal entry engine
              for this client. Until then this page shows the company profile only.
            </p>
          </Card>
        </div>
      </PageBody>
    </>
  )
}
