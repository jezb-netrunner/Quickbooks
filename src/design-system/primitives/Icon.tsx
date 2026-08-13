import {
  AlertCircle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowRight,
  Banknote,
  BookOpen,
  Boxes,
  Briefcase,
  Building2,
  Calendar,
  CalendarClock,
  Check,
  CheckCircle2,
  ChevronsUpDown,
  ClipboardList,
  Clock,
  Columns2,
  CreditCard,
  Divide,
  Download,
  FileCheck,
  HelpCircle,
  Inbox,
  Info,
  Landmark,
  Layers,
  LayoutDashboard,
  Library,
  ListTree,
  LogOut,
  Package,
  Paperclip,
  Percent,
  PieChart,
  Plus,
  Receipt,
  RotateCcw,
  Scale,
  Search,
  Settings,
  SlidersHorizontal,
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
  banknote: Banknote,
  'book-open': BookOpen,
  boxes: Boxes,
  briefcase: Briefcase,
  'building-2': Building2,
  calendar: Calendar,
  'calendar-clock': CalendarClock,
  check: Check,
  'check-circle-2': CheckCircle2,
  'chevrons-up-down': ChevronsUpDown,
  'clipboard-list': ClipboardList,
  clock: Clock,
  'columns-2': Columns2,
  'credit-card': CreditCard,
  divide: Divide,
  download: Download,
  'file-check': FileCheck,
  'help-circle': HelpCircle,
  inbox: Inbox,
  info: Info,
  landmark: Landmark,
  layers: Layers,
  'layout-dashboard': LayoutDashboard,
  library: Library,
  'list-tree': ListTree,
  'log-out': LogOut,
  package: Package,
  paperclip: Paperclip,
  percent: Percent,
  'pie-chart': PieChart,
  plus: Plus,
  receipt: Receipt,
  'rotate-ccw': RotateCcw,
  scale: Scale,
  search: Search,
  'sliders-horizontal': SlidersHorizontal,
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
