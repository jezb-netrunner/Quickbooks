// Every key is namespaced so switching clients (or users) can never bleed
// cached rows across tenants. The whole cache is additionally cleared on any
// auth change (see AuthProvider).
export const keys = {
  memberships: ['memberships'] as const,
  clients: ['clients'] as const,
  client: (clientId: string) => ['client', clientId] as const,
  members: (firmId: string) => ['members', firmId] as const,
  assignments: (firmId: string) => ['assignments', firmId] as const,
}
