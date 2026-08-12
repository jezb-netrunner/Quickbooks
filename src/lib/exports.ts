// One export path for every report: CSV (no dependencies), Excel and PDF via
// dynamically imported libraries so neither ships in the main bundle.
import { downloadCsv } from './csv'

export interface ReportExport {
  /** File-safe base name, no extension. */
  filename: string
  /** Printed on the PDF header. */
  title: string
  /** Context lines under the PDF title (client name, date range). */
  subtitle: string[]
  header: string[]
  rows: (string | number)[][]
  /** Column indexes to right-align (money) in the PDF. */
  numericColumns?: number[]
}

export function exportCsv(report: ReportExport) {
  downloadCsv(`${report.filename}.csv`, report.header, report.rows)
}

export async function exportXlsx(report: ReportExport) {
  const XLSX = await import('xlsx')
  const sheet = XLSX.utils.aoa_to_sheet([report.header, ...report.rows])
  sheet['!cols'] = report.header.map((h, i) => ({
    wch: Math.max(
      h.length + 2,
      ...report.rows.slice(0, 200).map((r) => String(r[i] ?? '').length + 2),
    ),
  }))
  const book = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(book, sheet, report.title.slice(0, 31))
  XLSX.writeFile(book, `${report.filename}.xlsx`)
}

export async function exportPdf(report: ReportExport) {
  const { jsPDF } = await import('jspdf')
  const { default: autoTable } = await import('jspdf-autotable')
  const doc = new jsPDF({ orientation: report.header.length > 6 ? 'landscape' : 'portrait' })

  doc.setFont('helvetica', 'bold')
  doc.setFontSize(14)
  doc.setTextColor(27, 42, 74) // ink
  doc.text(report.title, 14, 16)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  doc.setTextColor(107, 104, 98) // warm gray
  report.subtitle.forEach((line, i) => doc.text(line, 14, 22 + i * 4.5))

  autoTable(doc, {
    startY: 24 + report.subtitle.length * 4.5,
    head: [report.header],
    body: report.rows.map((r) => r.map((v) => String(v))),
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 2, textColor: [34, 48, 78] },
    headStyles: { fillColor: [27, 42, 74], textColor: [247, 245, 241], fontStyle: 'bold' },
    alternateRowStyles: { fillColor: [247, 245, 241] },
    columnStyles: Object.fromEntries(
      (report.numericColumns ?? []).map((i) => [i, { halign: 'right' as const }]),
    ),
    didDrawPage: () => {
      const page = doc.internal.pageSize
      doc.setFontSize(7)
      doc.setTextColor(139, 134, 128)
      doc.text(`Generated ${new Date().toLocaleDateString('en-PH')} · Larkspur Books`, 14, page.getHeight() - 8)
    },
  })

  doc.save(`${report.filename}.pdf`)
}
