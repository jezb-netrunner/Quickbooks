import { createBrowserRouter, Navigate } from 'react-router-dom'
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
import { BirBooksPage } from './features/reports/routes/BirBooksPage'
import { TaxCodesPage } from './features/tax/TaxCodesPage'
import { ContactsPage } from './features/contacts/routes/ContactsPage'
import { DocumentsPage } from './features/documents/DocumentsPage'
import { ItemsPage } from './features/inventory/ItemsPage'
import { AdjustmentsPage } from './features/inventory/AdjustmentsPage'
import { ValuationPage } from './features/inventory/ValuationPage'
import { CashAccountsPage } from './features/cash/CashAccountsPage'

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
            { path: 'customers', element: <ContactsPage side="customer" /> },
            { path: 'vendors', element: <ContactsPage side="vendor" /> },
            { path: 'invoices', element: <DocumentsPage docType="invoice" /> },
            { path: 'collections', element: <DocumentsPage docType="receipt" /> },
            { path: 'purchases', element: <DocumentsPage docType="purchase" /> },
            { path: 'bills', element: <DocumentsPage docType="bill" /> },
            { path: 'expenses', element: <DocumentsPage docType="expense" /> },
            { path: 'payments', element: <DocumentsPage docType="disbursement" /> },
            { path: 'items', element: <ItemsPage /> },
            { path: 'stock-adjustments', element: <AdjustmentsPage /> },
            { path: 'valuation', element: <ValuationPage /> },
            { path: 'cash', element: <CashAccountsPage /> },
            // Old paths keep working: bookmarks predate the cycle regrouping.
            { path: 'contacts', element: <Navigate to="../customers" replace /> },
            { path: 'money-in', element: <Navigate to="../collections" replace /> },
            { path: 'money-out', element: <Navigate to="../payments" replace /> },
            { path: 'coa', element: <CoaPage /> },
            { path: 'journal', element: <JournalPage /> },
            { path: 'periods', element: <PeriodsPage /> },
            { path: 'trial-balance', element: <TrialBalancePage /> },
            { path: 'profit-and-loss', element: <PnlPage /> },
            { path: 'balance-sheet', element: <BalanceSheetPage /> },
            { path: 'cash-flow', element: <CashFlowPage /> },
            { path: 'general-ledger', element: <GeneralLedgerPage /> },
            { path: 'bir-books', element: <BirBooksPage /> },
            { path: 'aging', element: <AgingPage /> },
            { path: 'tax-codes', element: <TaxCodesPage /> },
            { path: 'settings', element: <ClientSettingsPage /> },
          ],
        },
      ],
    },
  ],
  { basename: import.meta.env.BASE_URL },
)
