export interface TabItem {
  value: string
  label: string
  count?: number
}

export interface TabsProps {
  items: TabItem[]
  value: string
  onChange: (value: string) => void
  variant?: 'underline' | 'pill'
  className?: string
}

export function Tabs({ items, value, onChange, variant = 'underline', className }: TabsProps) {
  const classes = ['fis-tabs', variant === 'pill' ? 'fis-tabs--pill' : '', className ?? '']
    .filter(Boolean)
    .join(' ')
  return (
    <div className={classes} role="tablist">
      {items.map((item) => {
        const on = item.value === value
        return (
          <button
            key={item.value}
            type="button"
            role="tab"
            aria-selected={on}
            className={`fis-tabs__tab${on ? ' fis-tabs__tab--on' : ''}`}
            onClick={() => onChange(item.value)}
          >
            {item.label}
            {item.count !== undefined && <span className="fis-tabs__count">{item.count}</span>}
          </button>
        )
      })}
    </div>
  )
}
