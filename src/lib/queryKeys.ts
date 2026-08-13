// Every key is namespaced so switching clients (or users) can never bleed
// cached rows across tenants. The whole cache is additionally cleared on any
// auth change (see AuthProvider).
export const keys = {
  memberships: ['memberships'] as const,
  clients: ['clients'] as const,
  client: (clientId: string) => ['client', clientId] as const,
  members: (firmId: string) => ['members', firmId] as const,
  assignments: (firmId: string) => ['assignments', firmId] as const,
  accounts: (clientId: string) => ['accounts', clientId] as const,
  periods: (clientId: string) => ['periods', clientId] as const,
  entries: (clientId: string) => ['entries', clientId] as const,
  entryLines: (clientId: string, entryId: string) => ['entry-lines', clientId, entryId] as const,
  trialBalance: (clientId: string, from: string, to: string) =>
    ['trial-balance', clientId, from, to] as const,
  contacts: (clientId: string) => ['contacts', clientId] as const,
  documents: (clientId: string, docType: string) => ['documents', clientId, docType] as const,
  documentDetail: (clientId: string, documentId: string) =>
    ['document-detail', clientId, documentId] as const,
  openItems: (clientId: string, docType: string, asOf: string) =>
    ['open-items', clientId, docType, asOf] as const,
  aging: (clientId: string, docType: string, asOf: string) =>
    ['aging', clientId, docType, asOf] as const,
  dashboard: (clientId: string) => ['dashboard', clientId] as const,
  pnl: (clientId: string, from: string, to: string) => ['pnl', clientId, from, to] as const,
  balanceSheet: (clientId: string, asOf: string) => ['balance-sheet', clientId, asOf] as const,
  cashFlow: (clientId: string, from: string, to: string) =>
    ['cash-flow', clientId, from, to] as const,
  generalLedger: (clientId: string, accountId: string, from: string, to: string) =>
    ['general-ledger', clientId, accountId, from, to] as const,
  taxProfile: (clientId: string) => ['tax-profile', clientId] as const,
  taxCodes: (clientId: string) => ['tax-codes', clientId] as const,
  birBook: (clientId: string, book: string, from: string, to: string) =>
    ['bir-book', clientId, book, from, to] as const,
}
