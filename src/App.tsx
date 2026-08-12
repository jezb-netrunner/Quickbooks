import { Component, StrictMode, type ErrorInfo, type ReactNode } from 'react'
import { RouterProvider } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AuthProvider } from './auth/AuthProvider'
import { router } from './router'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Free-tier discipline: no refetch storms; data is refetched on
      // invalidation after mutations.
      staleTime: 30_000,
      retry: 1,
    },
  },
})

interface BoundaryState {
  error: Error | null
}

// A render error must never be a white screen: show what happened and offer
// the one useful action.
class AppErrorBoundary extends Component<{ children: ReactNode }, BoundaryState> {
  state: BoundaryState = { error: null }

  static getDerivedStateFromError(error: Error): BoundaryState {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Unhandled render error:', error, info.componentStack)
  }

  render() {
    if (!this.state.error) return this.props.children
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
        <div
          style={{
            width: '100%',
            maxWidth: 460,
            background: 'var(--surface-card)',
            border: '1px solid var(--border-subtle)',
            borderRadius: 'var(--radius-lg)',
            boxShadow: 'var(--shadow-sm)',
            padding: 24,
          }}
        >
          <h1 style={{ font: 'var(--type-h2)' }}>Something broke on this screen</h1>
          <p style={{ marginTop: 8, font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
            The error has been logged to the browser console. Reloading usually clears it; if it
            keeps happening, report what you clicked.
          </p>
          <p
            style={{
              marginTop: 12,
              font: '400 12px/1.5 var(--font-mono)',
              color: 'var(--clay-600)',
              overflowWrap: 'anywhere',
            }}
          >
            {this.state.error.message}
          </p>
          <button
            type="button"
            onClick={() => window.location.reload()}
            style={{
              marginTop: 16,
              height: 38,
              padding: '0 14px',
              background: 'var(--ink-800)',
              color: 'var(--sand-100)',
              border: 'none',
              borderRadius: 'var(--radius-md)',
              font: '500 14px/1 var(--font-sans)',
              cursor: 'pointer',
            }}
          >
            Reload
          </button>
        </div>
      </div>
    )
  }
}

export function App() {
  return (
    <StrictMode>
      <AppErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <AuthProvider>
            <RouterProvider router={router} />
          </AuthProvider>
        </QueryClientProvider>
      </AppErrorBoundary>
    </StrictMode>
  )
}
