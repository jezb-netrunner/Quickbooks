import { createRoot, type Root } from 'react-dom/client'

// Self-hosted fonts — no CDN dependency (see design-system/index.css).
import '@fontsource/space-grotesk/500.css'
import '@fontsource/space-grotesk/600.css'
import '@fontsource/space-grotesk/700.css'
import '@fontsource/inter/400.css'
import '@fontsource/inter/500.css'
import '@fontsource/inter/600.css'
import '@fontsource/inter/700.css'
import '@fontsource/ibm-plex-mono/400.css'
import '@fontsource/ibm-plex-mono/500.css'
import '@fontsource/ibm-plex-mono/600.css'
import './design-system/index.css'

import { readEnv } from './lib/env'

// Configuration is checked BEFORE the app (and the Supabase client) is even
// loaded, so a missing or broken setup renders a readable screen instead of a
// white page with the error buried in the console.
function ConfigScreen({ heading, lines, detail }: { heading: string; lines: string[]; detail?: string }) {
  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'grid',
        placeItems: 'center',
        background: 'var(--surface-page)',
        padding: 24,
      }}
    >
      <div style={{ width: '100%', maxWidth: 520, display: 'grid', gap: 20 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'center' }}>
          <span
            style={{
              fontFamily: 'var(--font-display)',
              fontWeight: 600,
              fontSize: 24,
              letterSpacing: '-0.03em',
              color: 'var(--text-primary)',
            }}
          >
            Larkspur
          </span>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: 'var(--amber-500)' }} />
        </div>
        <div
          style={{
            background: 'var(--surface-card)',
            border: '1px solid var(--border-subtle)',
            borderRadius: 'var(--radius-lg)',
            boxShadow: 'var(--shadow-sm)',
            padding: 24,
            display: 'grid',
            gap: 10,
          }}
        >
          <h1 style={{ font: 'var(--type-h2)' }}>{heading}</h1>
          {lines.map((line) => (
            <p key={line} style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              {line}
            </p>
          ))}
          {detail && (
            <p
              style={{
                font: '400 12px/1.5 var(--font-mono)',
                color: 'var(--clay-600)',
                overflowWrap: 'anywhere',
              }}
            >
              {detail}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}

function renderMissingConfig(root: Root, missing: string[]) {
  root.render(
    <ConfigScreen
      heading="This deployment is not configured yet"
      lines={[
        `The build ran without: ${missing.join(', ')}.`,
        'Deployed site: set the two repository variables under Settings → Secrets and variables → Actions → Variables, then re-run the deploy workflow. The values come from your Supabase project (docs/runbooks/hosted-project-setup.md).',
        'Local development: copy .env.example to .env.local and fill in the values `supabase start` prints.',
      ]}
    />,
  )
}

const root = createRoot(document.getElementById('root')!)
const config = readEnv()

if (!config.ok) {
  renderMissingConfig(root, config.missing)
} else {
  import('./App')
    .then(({ App }) => root.render(<App />))
    .catch((error: unknown) => {
      // e.g. a malformed VITE_SUPABASE_URL makes the Supabase client refuse to
      // construct — still a configuration problem, still shown on the page.
      root.render(
        <ConfigScreen
          heading="The app could not start"
          lines={[
            'Loading failed before the first screen. Check the two VITE_SUPABASE_* values for typos and re-run the deploy workflow.',
          ]}
          detail={error instanceof Error ? error.message : String(error)}
        />,
      )
    })
}
