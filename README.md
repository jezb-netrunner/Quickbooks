# Larkspur Books

A multi-client accounting platform for a Philippine CPA practice: one login for
the practice, many client companies with fully separate books, built for BIR
compliance. The build spec is [`Initial README.md`](./Initial%20README.md); the
approved architecture is [ADR-0001](./docs/decisions/ADR-0001-phase1-blueprint.md).

**Stack:** Vite + React + TypeScript + Tailwind v4 SPA on GitHub Pages;
Supabase (Postgres, Auth) free tier. There is no server: every integrity and
access rule lives in Postgres — RLS, constraints, triggers, and SQL functions.
The browser is untrusted.

## Phase status

- [x] **Phase 1** — scaffold, Pages deploy, auth, firm/client/membership
      schema + RLS with isolation tests, firm admin console, client switcher
- [x] **Phase 2** — chart of accounts (PH SME template), monthly periods with
      close/lock, immutable double-entry journal engine, reversals, trial balance
- [ ] Phase 3 — documents posting through the engine; AR/AP subledgers
- [ ] Phase 4 — financial statements, GL drill-down
- [ ] Phase 5 — tax profile, VAT/EWT automation, BIR books
- [ ] Phase 6 — return working papers, compliance calendar, 2307s
- [ ] Phase 7 — bank import, attachments, review workflow, practice dashboard

## Local development

Prereqs: Node 22+, Docker (for the local Supabase stack).

```sh
npm ci
npx supabase start        # local Postgres + auth + API; prints the anon key
cp .env.example .env.local  # paste the printed anon key
npm run dev               # http://localhost:5173
```

`supabase db reset` rebuilds the local database from `supabase/migrations/` in
order and loads `supabase/seed.sql` — fictional demo data only. Demo logins
(local stack only, password `demo-password-123`): `owner@demo.larkspur.ph`,
`staff@demo.larkspur.ph`, `unassigned@demo.larkspur.ph`,
`viewer@demo.larkspur.ph`, `other@demo.larkspur.ph`.

## Tests

```sh
supabase db reset   # proves every migration runs clean on a fresh database
supabase test db    # pgTAP isolation suite (supabase/tests/)
npm run typecheck && npm run lint && npm run build
```

The pgTAP suite is the security boundary's proof: firm A cannot read firm B,
unassigned staff see nothing, client viewers are read-only and confined to one
client, and every escalation/transition path fails closed. CI
(`.github/workflows/db-tests.yml`) runs all of it on every push and PR.

## Schema changes

All schema changes are ordered, idempotent SQL files in `supabase/migrations/`
— never dashboard SQL. After changing the schema, regenerate the client types
against the running local stack and commit them in the same PR:

```sh
npm run gen:types
```

Deploys to the hosted project go through `supabase db push` from `main`
(see `docs/runbooks/hosted-project-setup.md`).

## Repository map

```
supabase/migrations/   the schema, RLS policies, RPCs — the actual product
supabase/tests/        pgTAP isolation suite
src/design-system/     Fiscana tokens (verbatim) + primitives + Tailwind map
src/shell/             app chrome: sidebar, top bar, client switcher
src/features/          one folder per vertical; Phase 1: firm/, clients/
docs/decisions/        ADRs — start with ADR-0001
docs/runbooks/         manual hosted-project state that cannot live in git
```
