// The user's working day, not UTC's. `new Date().toISOString()` is UTC —
// in the Philippines (UTC+8) that reads as YESTERDAY between midnight and
// 8am, which would default document dates a day early and hide same-day
// postings from reports. en-CA formats as YYYY-MM-DD in local time.
export function localToday(): string {
  return new Date().toLocaleDateString('en-CA')
}
