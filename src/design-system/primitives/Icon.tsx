import {
  AlertCircle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowRight,
  BookOpen,
  Building2,
  Calendar,
  Check,
  CheckCircle2,
  ChevronsUpDown,
  Clock,
  Columns2,
  CreditCard,
  Download,
  FileCheck,
  HelpCircle,
  Info,
  Landmark,
  LayoutDashboard,
  Library,
  ListTree,
  LogOut,
  PieChart,
  Plus,
  Receipt,
  RotateCcw,
  Scale,
  Search,
  Settings,
  Trash2,
  TrendingUp,
  Upload,
  Users,
  Wallet,
  Waves,
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
  'book-open': BookOpen,
  'building-2': Building2,
  calendar: Calendar,
  check: Check,
  'check-circle-2': CheckCircle2,
  'chevrons-up-down': ChevronsUpDown,
  clock: Clock,
  'columns-2': Columns2,
  'credit-card': CreditCard,
  download: Download,
  'file-check': FileCheck,
  'help-circle': HelpCircle,
  info: Info,
  landmark: Landmark,
  'layout-dashboard': LayoutDashboard,
  library: Library,
  'list-tree': ListTree,
  'log-out': LogOut,
  'pie-chart': PieChart,
  plus: Plus,
  receipt: Receipt,
  'rotate-ccw': RotateCcw,
  scale: Scale,
  search: Search,
  'trash-2': Trash2,
  'trending-up': TrendingUp,
  settings: Settings,
  upload: Upload,
  users: Users,
  wallet: Wallet,
  waves: Waves,
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
