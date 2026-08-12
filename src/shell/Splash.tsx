export function Splash() {
  return (
    <div
      style={{
        height: '100vh',
        display: 'grid',
        placeItems: 'center',
        background: 'var(--surface-page)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <span
          style={{
            fontFamily: 'var(--font-display)',
            fontWeight: 600,
            fontSize: 21,
            letterSpacing: '-0.03em',
            color: 'var(--text-primary)',
          }}
        >
          Larkspur
        </span>
        <span style={{ width: 7, height: 7, borderRadius: 2, background: 'var(--amber-500)' }} />
      </div>
    </div>
  )
}
