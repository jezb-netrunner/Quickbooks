import { createBrowserRouter } from 'react-router-dom'
import { RequireAuth } from './auth/RequireAuth'
import { LoginPage } from './auth/routes/LoginPage'
import { SignupPage } from './auth/routes/SignupPage'
import { ResetRequestPage } from './auth/routes/ResetRequestPage'
import { UpdatePasswordPage } from './auth/routes/UpdatePasswordPage'
import { AuthCallbackPage } from './auth/routes/AuthCallbackPage'
import { HomeRedirect } from './features/clients/routes/HomeRedirect'
import { SelectClientPage } from './features/clients/routes/SelectClientPage'
import { CreateFirmPage } from './features/clients/routes/CreateFirmPage'
import { ClientLayout } from './features/clients/routes/ClientLayout'
import { ClientOverviewPage } from './features/clients/routes/ClientOverviewPage'
import { ClientSettingsPage } from './features/clients/routes/ClientSettingsPage'
import { FirmPage } from './features/firm/FirmPage'
import { CoaPage } from './features/coa/routes/CoaPage'
import { JournalPage } from './features/journal/routes/JournalPage'
import { PeriodsPage } from './features/periods/routes/PeriodsPage'
import { TrialBalancePage } from './features/reports/routes/TrialBalancePage'
import { AgingPage } from './features/reports/routes/AgingPage'
import { PnlPage } from './features/reports/routes/PnlPage'
import { BalanceSheetPage } from './features/reports/routes/BalanceSheetPage'
import { CashFlowPage } from './features/reports/routes/CashFlowPage'
import { GeneralLedgerPage } from './features/reports/routes/GeneralLedgerPage'
import { ContactsPage } from './features/contacts/routes/ContactsPage'
import { DocumentsPage } from './features/documents/DocumentsPage'

// The active client is always the /c/:clientId URL segment — never only local
// state. Phase 2+ screens (coa, journal, periods, …) slot in as siblings of
// the client routes below.
export const router = createBrowserRouter(
  [
    { path: '/login', element: <LoginPage /> },
    { path: '/signup', element: <SignupPage /> },
    { path: '/reset-password', element: <ResetRequestPage /> },
    { path: '/update-password', element: <UpdatePasswordPage /> },
    { path: '/auth/callback', element: <AuthCallbackPage /> },
    {
      element: <RequireAuth />,
      children: [
        { path: '/', element: <HomeRedirect /> },
        { path: '/select-client', element: <SelectClientPage /> },
        { path: '/create-firm', element: <CreateFirmPage /> },
        { path: '/firm', element: <FirmPage /> },
        {
          path: '/c/:clientId',
          element: <ClientLayout />,
          children: [
            { index: true, element: <ClientOverviewPage /> },
            { path: 'contacts', element: <ContactsPage /> },
            { path: 'invoices', element: <DocumentsPage docType="invoice" /> },
            { path: 'bills', element: <DocumentsPage docType="bill" /> },
            { path: 'money-in', element: <DocumentsPage docType="receipt" /> },
            { path: 'money-out', element: <DocumentsPage docType="disbursement" /> },
            { path: 'coa', element: <CoaPage /> },
            { path: 'journal', element: <JournalPage /> },
            { path: 'periods', element: <PeriodsPage /> },
            { path: 'trial-balance', element: <TrialBalancePage /> },
            { path: 'profit-and-loss', element: <PnlPage /> },
            { path: 'balance-sheet', element: <BalanceSheetPage /> },
            { path: 'cash-flow', element: <CashFlowPage /> },
            { path: 'general-ledger', element: <GeneralLedgerPage /> },
            { path: 'aging', element: <AgingPage /> },
            { path: 'settings', element: <ClientSettingsPage /> },
          ],
        },
      ],
    },
  ],
  { basename: import.meta.env.BASE_URL },
)
