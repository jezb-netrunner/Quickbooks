# ADR-0001 — Phase 1 blueprint (approved 12 Aug 2026)

Status: **accepted**. This records the approved Phase 1 schema/architecture and
the decisions later phases must not silently reverse. The build spec is
`Initial README.md` at the repo root.

## Owner-approved decisions

1. **Signup policy** — public signup stays enabled only long enough to create
   the practice's own accounts, then gets disabled on the hosted project
   (runbook `docs/runbooks/hosted-project-setup.md`). `create_firm` requires a
   verified email and is limited to one firm per creator regardless.
2. **Repo visibility** — public repo (GitHub Pages free plan). The anon key and
   bundle are public by design; **no real client data ever enters the repo** —
   `seed.sql` and test fixtures are fictional only.
3. **Audit log** — ships in Phase 1, scoped to the four administrative tables
   (`firms`, `clients`, `memberships`, `client_assignments`). The ledger is
   never row-imaged; Phase 2+ audits state transitions.
4. **Viewer privacy** — `client_viewer` sees no profile but their own (viewers
   can be competing businesses). Costs "prepared by" attribution on viewer
   screens until a narrower disclosure exists.

## Access model

Roles (`text` + CHECK, not enums — transaction-safe migrations): `firm_admin`,
`reviewer` (staff semantics until Phase 7), `staff`, `client_viewer`.

- Default-closed: staff/reviewer with zero `client_assignments` rows and
  `has_all_clients=false` see nothing. Whole-firm access is an explicit flag.
- `client_viewer` binds to exactly one client via `memberships.client_id` +
  CHECK + composite FK — declarative, race-free.
- Membership mutations only via SECURITY DEFINER RPCs (`create_firm`,
  `add_member`, `update_member`, `remove_member`, `set_client_assignments`);
  zero DML grants. Constraint triggers re-enforce invariants (last-admin,
  assignment-role) as a second wall, including against cascade deletes.
- RPCs take `pg_advisory_xact_lock` on the firm id — closes TOCTOU races.
- Every membership-granting path requires a verified email
  (`auth.users.email_confirmed_at`).
- Membership removal is a **hard delete**; history lives in `audit_log`.
  No `revoked_at` filter class exists to be forgotten.

## RLS architecture (the template every phase inherits)

- Helpers are SECURITY DEFINER, `search_path = ''`, in the non-API-exposed
  `app` schema (recursion fix; hosted Supabase offers no BYPASSRLS). Tables are
  `ENABLE`d, never `FORCE`d. No JWT claims are used for authorization.
- Every access branch is **role-gated**, so role transitions can never read
  through stale grants.
- The permanent two-line contract for every future client-scoped table:
  ```sql
  for select using (client_id in (select app.accessible_client_ids()))
  for insert/update ... with check ((select app.can_write_client(client_id)))
  ```
- Grants hygiene (migration 000100): revoke Supabase's blanket defaults from
  `anon` AND `authenticated`, revoke default privileges so future tables are
  born closed, revoke CREATE on `public`. Column-level grants double as
  immutability (`clients.firm_id`, `functional_currency`, attribution columns).
- Meta-tests (001_meta.sql) tripwire forever: RLS on every table, pinned
  `search_path` on definer functions, zero anon privileges, every view
  `security_invoker`, empty realtime publication.

## House rules for later phases

- Every business table: `client_id NOT NULL` + `unique (id, client_id)` anchor;
  children reference via **composite FKs** so cross-tenant rows are
  unrepresentable.
- Money `numeric(18,2)`; business dates `date` (Asia/Manila semantics); no
  hardcoded tax rates or deadlines — versioned, effective-dated reference
  tables, shipped as data migrations (`on conflict do nothing`).
- The PH tax profile is a separate **effective-dated** table in Phase 5
  (`client_tax_profiles` + overlap exclusion) — never columns on `clients`.
- **Phase 2 obligation:** once `periods` exist, trigger-block changes to
  `clients.fiscal_year_end_month` (and revisit `reporting_basis` mutability).
- Ledger conventions (from the free-tier arithmetic: worst case ≈455 MB at
  30 clients × 500 txns/mo × 36 months): ≤2 secondary indexes on ledger-scale
  tables, narrow rows, no jsonb on lines, never row-image the ledger,
  no partitioning/materialized reports, attachments to Storage never bytea.
- Storage (Phase 7): bucket policies reuse `app.can_access_client()` on the
  path's client segment; no public buckets. Realtime: any future channel must
  be private with authorization; the publication stays empty until then.
- Views, if ever added, must be `security_invoker = true` (meta-test enforces).

## Frontend / deployment

- `/c/:clientId` uses the client **uuid**; `clients.code` is a display label
  for BIR books, never a lookup key. Forbidden and missing clients are
  indistinguishable (RLS returns zero rows → one 404-style screen).
- The client switcher is a bare RLS-filtered select on `clients` —
  deliberately NOT a SQL view (default definer views bypass RLS).
- GitHub Pages: `base` derives from `GITHUB_REPOSITORY` (the repo name never
  appears in source). SPA fallback is a post-build copy of `index.html` to
  `404.html`; the sessionStorage redirect hack exists for SEO status codes an
  auth-gated tool does not need — **do not "fix" this**.
- Supabase URL + anon key live in GitHub Actions repository **variables**.
  The service-role key exists nowhere in this repo, CI, or tests (pgTAP
  impersonates via `request.jwt.claims`).
- TanStack Query keys are clientId-namespaced; the cache clears on any auth
  change. Tailwind v4 `@theme inline` maps the verbatim Fiscana token CSS;
  fonts are self-hosted (@fontsource); icons are bundled lucide-react behind
  the design-system `Icon` registry.
- Naming: **"client" means a firm client company.** The mockups' "Clients &
  vendors" screen is `features/contacts/` (a client company's customers and
  vendors). This rename is load-bearing — do not blur it.

## Verification story

`supabase db reset` proves every migration runs cleanly, in order, on a fresh
database; `supabase test db` runs the six-file pgTAP suite (69 assertions:
isolation, default-closed assignments, viewer confinement, escalation paths,
transition attacks, structural meta-tests). CI runs both on every push and PR
plus the frontend gate. Never test against, or point the CLI at, the
production project.
