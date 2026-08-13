import { createContext, useContext } from 'react'
import { Link, Outlet, useParams } from 'react-router-dom'
import { Button, Card } from '@/design-system'
import { AppShell } from '@/shell/AppShell'
import { Sidebar } from '@/shell/Sidebar'
import { Splash } from '@/shell/Splash'
import { useClient } from '../hooks'
import type { Client } from '@/lib/database.types'

const ClientContext = createContext<Client | null>(null)

export function useActiveClient(): Client {
  const client = useContext(ClientContext)
  if (!client) throw new Error('useActiveClient must be used inside ClientLayout')
  return client
}

// The URL is the single source of truth for the active client. RLS makes
// "does not exist", "another firm's client", and "not assigned to you" all
// return zero rows — one 404-style screen, deliberately indistinguishable.
export function ClientLayout() {
  const { clientId = '' } = useParams()
  const { data: client, isPending, isError } = useClient(clientId)

  if (isPending) return <Splash />

  if (isError || !client) {
    return (
      <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', background: 'var(--surface-page)', padding: 24 }}>
        <div style={{ width: '100%', maxWidth: 420 }}>
          <Card title="Client not found" subtitle="This client does not exist, or you do not have access to it">
            <Link to="/select-client">
              <Button variant="secondary" iconLeft="arrow-left">
                Back to your clients
              </Button>
            </Link>
          </Card>
        </div>
      </div>
    )
  }

  const nav = [
    { to: `/c/${client.id}`, label: 'Dashboard', icon: 'layout-dashboard', end: true },
    { to: `/c/${client.id}/contacts`, label: 'Customers & vendors', icon: 'users' },
    { to: `/c/${client.id}/invoices`, label: 'Invoices', icon: 'receipt' },
    { to: `/c/${client.id}/bills`, label: 'Bills', icon: 'credit-card' },
    { to: `/c/${client.id}/money-in`, label: 'Money in', icon: 'arrow-left-right' },
    { to: `/c/${client.id}/money-out`, label: 'Money out', icon: 'wallet' },
    { to: `/c/${client.id}/journal`, label: 'Journal', icon: 'book-open' },
    { heading: 'Reports' },
    { to: `/c/${client.id}/trial-balance`, label: 'Trial balance', icon: 'scale' },
    { to: `/c/${client.id}/profit-and-loss`, label: 'Profit & loss', icon: 'trending-up' },
    { to: `/c/${client.id}/balance-sheet`, label: 'Balance sheet', icon: 'columns-2' },
    { to: `/c/${client.id}/cash-flow`, label: 'Cash flow', icon: 'waves' },
    { to: `/c/${client.id}/general-ledger`, label: 'General ledger', icon: 'library' },
    { to: `/c/${client.id}/bir-books`, label: 'BIR books', icon: 'landmark' },
    { to: `/c/${client.id}/aging`, label: 'AR/AP aging', icon: 'pie-chart' },
    { heading: 'Setup' },
    { to: `/c/${client.id}/coa`, label: 'Chart of accounts', icon: 'list-tree' },
    { to: `/c/${client.id}/tax-codes`, label: 'Tax codes', icon: 'file-check' },
    { to: `/c/${client.id}/periods`, label: 'Periods', icon: 'calendar' },
    { to: `/c/${client.id}/settings`, label: 'Client settings', icon: 'settings' },
  ]

  return (
    <ClientContext.Provider value={client}>
      <AppShell sidebar={<Sidebar items={nav} activeClientId={client.id} />}>
        <Outlet />
      </AppShell>
    </ClientContext.Provider>
  )
}
