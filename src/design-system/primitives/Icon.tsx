import {
  AlertCircle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowRight,
  Building2,
  Check,
  CheckCircle2,
  ChevronsUpDown,
  CreditCard,
  Download,
  FileCheck,
  HelpCircle,
  Info,
  Landmark,
  LayoutDashboard,
  LogOut,
  PieChart,
  Plus,
  Receipt,
  Search,
  Settings,
  Upload,
  Users,
  Wallet,
  X,
  type LucideIcon,
} from 'lucide-react'
import type { CSSProperties } from 'react'

// Wraps the bundled lucide set (no CDN fetch, unlike the design prototype) and
// pins the Fiscana convention: outline, 1.75px stroke, currentColor. A static
// registry — not lucide's full `icons` map — keeps the bundle tree-shakeable;
// add glyphs here as screens need them (never emoji, never one-off SVGs).
const REGISTRY: Record<string, LucideIcon> = {
  'alert-circle': AlertCircle,
  'arrow-left': ArrowLeft,
  'arrow-left-right': ArrowLeftRight,
  'arrow-right': ArrowRight,
  'building-2': Building2,
  check: Check,
  'check-circle-2': CheckCircle2,
  'chevrons-up-down': ChevronsUpDown,
  'credit-card': CreditCard,
  download: Download,
  'file-check': FileCheck,
  'help-circle': HelpCircle,
  info: Info,
  landmark: Landmark,
  'layout-dashboard': LayoutDashboard,
  'log-out': LogOut,
  'pie-chart': PieChart,
  plus: Plus,
  receipt: Receipt,
  search: Search,
  settings: Settings,
  upload: Upload,
  users: Users,
  wallet: Wallet,
  x: X,
}

export interface IconProps {
  name: string
  size?: number
  strokeWidth?: number
  title?: string
  style?: CSSProperties
  className?: string
}

export function Icon({ name, size = 18, strokeWidth = 1.75, title, style, className }: IconProps) {
  const Glyph = REGISTRY[name]
  if (!Glyph) return null
  return (
    <Glyph
      size={size}
      strokeWidth={strokeWidth}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      style={style}
      className={className}
    />
  )
}
