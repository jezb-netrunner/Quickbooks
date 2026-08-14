// P4-04 regression: CSV/spreadsheet formula-injection is neutralized on export,
// without mangling legitimate numbers. Run with:
//   node --experimental-strip-types scripts/test-csv-injection.ts
import { csvCell } from '../src/lib/csv.ts'

let pass = 0
let fail = 0
function check(name: string, got: string, want: string) {
  if (got === want) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}\n         got:  ${JSON.stringify(got)}\n         want: ${JSON.stringify(want)}`)
  }
}

// Formula/DDE payloads must be neutralized with a leading single quote.
check('=WEBSERVICE attack is neutralized', csvCell('=WEBSERVICE("http://evil/x")'), `"'=WEBSERVICE(""http://evil/x"")"`)
check('+cmd attack is neutralized', csvCell('+cmd|/c calc'), "'+cmd|/c calc")
check('@SUM attack is neutralized', csvCell('@SUM(1+1)'), "'@SUM(1+1)")
check('-2+3+cmd attack is neutralized', csvCell('-2+3+cmd|x'), "'-2+3+cmd|x")
check('leading TAB is neutralized', csvCell('\t=1'), "'\t=1")

// Legitimate data must NOT be altered.
check('plain contact name untouched', csvCell('Acme Trading Inc'), 'Acme Trading Inc')
check('negative NUMBER stays numeric', csvCell(-1234.5), '-1234.5')
check('negative numeric STRING stays numeric', csvCell('-1234.50'), '-1234.50')
check('positive number untouched', csvCell(500), '500')
check('comma value is quoted only', csvCell('Manila, PH'), '"Manila, PH"')

console.log(`\nCSV injection test: ${pass} passed, ${fail} failed`)
if (fail > 0) {
  console.log('RESULT: FAIL')
  process.exit(1)
}
console.log('RESULT: PASS')
