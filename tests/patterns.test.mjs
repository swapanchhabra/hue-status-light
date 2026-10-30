// Checks that hooks/register.ts and scripts/hue-status.sh (testcheck) use the same
// test-run pattern, and that the JavaScript form classifies tests/commands.txt.
// Usage: node tests/patterns.test.mjs
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../plugins/hue-status-light/', import.meta.url))
const ts = readFileSync(root + 'hooks/register.ts', 'utf8')
const sh = readFileSync(root + 'scripts/hue-status.sh', 'utf8')
const tsSrc = ts.match(/^const TEST_SRC = '([^']*)'$/m)?.[1]
const shSrc = sh.match(/^\s*TEST_RE='([^']*)'$/m)?.[1]

let failed = 0
const check = (ok, msg) => { if (!ok) { failed++; console.log('FAIL ' + msg) } }

check(tsSrc && shSrc, 'found TEST_SRC in register.ts and TEST_RE in hue-status.sh')
check(tsSrc === shSrc, 'register.ts TEST_SRC equals hue-status.sh TEST_RE')

const re = new RegExp(tsSrc.replaceAll('[:space:]', '\\s'), 'm')
const cases = readFileSync(fileURLToPath(new URL('commands.txt', import.meta.url)), 'utf8')
  .split('\n').filter(l => l && !l.startsWith('#'))
for (const line of cases) {
  const [want, cmd] = line.split('\t')
  check(re.test(cmd) === (want === 'yes'), `js: expected ${want} for: ${cmd}`)
}

console.log(failed ? `${failed} failed` : `ok: ${cases.length} commands`)
process.exit(failed ? 1 : 0)
