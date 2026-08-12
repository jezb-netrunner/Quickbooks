// GitHub Pages serves 404.html for any unknown path. Copying the built
// index.html makes every deep link (e.g. /c/:clientId/reports) load the SPA;
// react-router reads location.pathname normally and PKCE auth-callback query
// params pass through untouched. The sessionStorage-redirect hack exists only
// to return 200 status codes for SEO, which an auth-gated tool does not need —
// see docs/decisions/ADR-0001. Do not "fix" this.
import { copyFileSync } from 'node:fs'

copyFileSync('dist/index.html', 'dist/404.html')
console.log('dist/404.html written (SPA fallback)')
