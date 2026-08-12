# Runbook — hosted Supabase project setup

Manual dashboard state that cannot live in git. Re-check this list after any
dashboard visit; drift here is invisible to CI.

## One-time setup

1. Create the Supabase project (free tier). Note the project URL and anon key.
2. **Auth → URL configuration**
   - Site URL: `https://<owner>.github.io/<repo>/`
   - Additional redirect URLs:
     - `https://<owner>.github.io/<repo>/**`
     - `http://localhost:5173/**`
3. **Auth → Providers → Email**
   - Confirm email: **ON** (matches `supabase/config.toml`; the SQL
     verified-email checks enforce it regardless, but keep them aligned).
   - Minimum password length: 10.
4. **GitHub repository → Settings → Secrets and variables → Actions →
   Variables** (variables, not secrets — these are public by design):
   - `VITE_SUPABASE_URL` = the project URL
   - `VITE_SUPABASE_ANON_KEY` = the anon key
5. **GitHub repository → Settings → Pages**: Source = GitHub Actions.
6. Deploy the schema: `supabase link --project-ref <ref>` then
   `supabase db push` from `main`. Never run SQL in the dashboard editor
   without committing the same SQL as a migration.

## After the practice's own accounts exist (approved decision 1)

7. Sign up the owner account, confirm the email, sign in, create the firm.
8. Create staff accounts the same way (sign up + confirm), connect them via
   Firm settings → Members.
9. **Auth → Providers → Email → disable new user signups.** From here on,
   accounts are created by the practice only (temporarily re-enable when
   onboarding someone new, or create users from the dashboard's Auth section).

## Known free-tier limits

- **Built-in SMTP is rate-limited** to a handful of auth emails per hour —
  fine for setup, not for bulk onboarding. Configure custom SMTP
  (Auth → SMTP) if password resets start bouncing.
- **Projects pause after ~7 days of inactivity.** Restore from the dashboard
  (Project → Restore). Data is kept; the first restore can take a few minutes.
- Never point `supabase test db` or `db reset` at the hosted project.
