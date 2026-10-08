#!/usr/bin/env node
// Mutation testing of the contracts: coverage says every line runs, this says whether the tests would notice a bug
// there. It makes mutants of the contracts' sources by a few operator rules, applies one at a time to its file, runs
// the tests on it and puts the file back, whatever happens: a failure, Ctrl-C or a signal restores it before the script
// exits, and a run killed outright leaves a journal (cache/mutation/inflight.json) from which the next one
// restores it first. A mutant some test fails on is killed; one every test passes on survived: a test is missing there,
// or the mutant changes nothing anyone can observe (an equivalent mutant). One that does not compile is no mutant, and
// counts apart.
//
//   node scripts/mutation.mjs                                every mutant of the four files below
//   node scripts/mutation.mjs --list                         the mutants, without running them
//   node scripts/mutation.mjs --sample 120 --seed 7          120 of them, the same for the same seed and sources
//   node scripts/mutation.mjs --file src/DuelRouter.sol --line 230-243
//   node scripts/mutation.mjs --id DuelHook.sol:529:58,DuelMath.sol:92:19
//
// The rules, on code only (not on comments or NatSpec, strings, pragma, imports, nor the declarations of events and
// errors), one mutant per place:
//   comparison   < and <=, > and >=, == and != swapped
//   arithmetic   a binary + and -, * and / swapped
//   assignment   += and -= swapped
//   logical      && and || swapped
//   negation     a ! removed
//   guard        a revert removed, with the `if (...)` guarding it
//   literal      an integer literal one more: decimal, or hexadecimal up to 16 bits (one more on a 128-bit constant,
//                such as DuelMath.emaDecayX128's, changes nothing measurable)
//   return       `return x` returning 0, false, address(0) or bytesN(0) instead, in a function returning one such value
//
// The tests: `forge test` with the `mutation` profile of foundry.toml (the fastest build that compiles the
// hook), a fixed fuzz seed and --fail-fast, without the fork tests, the invariants and test/e2e, nor the gas and size
// bounds of the optimized build, which fail on that one (as in scripts/coverage.sh). And without forge's dynamic test
// linking: it leaves a test file uncompiled when a source's interface stays the same, and the code it holds of that
// source with it (the hook's creation code the deploy script holds, the library code inlined in a test), which would
// then test the original (the deploy script's attestation fails at once). Compiling them is what takes time, on one
// core for a forge: a mutant's tests run in several at once, each building in a folder of its own (out/mutation and
// cache/mutation), one for the tests of the mutated file (OWN), which kill most mutants in seconds, the others shared
// out between --jobs more. The first forge a test fails in stops the others: the verdict is the one a single
// `forge test --fail-fast` over every test would give.
//
// --file: a file to mutate, from the repository's root (several allowed; FILES by default). --line: its lines only (12, or 12-40).
// --id: these mutants only, as --list names them. --rule: these rules only. --sample: that many mutants, drawn with
// --seed (1 by default) from each file in proportion to its mutants, times its --weight (DuelHook.sol=2,DuelMath.sol=1;
// 1 by default). --jobs: the forges the tests other than the file's own are shared out between (3 by default).
// --report: the folder of report.json and summary.txt (cache/mutation by default). --profile: the foundry
// profile (`default` tests the optimized build, its gas bounds included, at twice the time). --timeout: the seconds a
// forge may take, after which the mutant counts as killed (900 by default). --no-baseline: no run of the tests on the
// unmutated sources first.
import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const CONTRACTS = ROOT
const STATE = path.join(CONTRACTS, 'cache', 'mutation')
const JOURNAL = path.join(STATE, 'inflight.json')

/** The files mutated by default, from the repository's root. */
export const FILES = [
  'src/DuelHook.sol',
  'src/DuelRouter.sol',
  'src/libraries/DuelMath.sol',
  'src/DuelFactory.sol',
]

/** The tests of each file, in a forge of their own: compiled without the others, they kill most mutants in seconds. */
export const OWN = {
  'src/DuelHook.sol': [
    'test/unit/DuelHook.t.sol',
    'test/unit/DuelHookRounds.t.sol',
    'test/unit/DuelHookArbitrage.t.sol',
  ],
  'src/DuelRouter.sol': ['test/unit/DuelRouter.t.sol', 'test/unit/DuelPermitSecurity.t.sol'],
  'src/libraries/DuelMath.sol': ['test/unit/DuelMath.t.sol'],
  'src/DuelFactory.sol': ['test/unit/DuelFactory.t.sol', 'test/unit/DuelConfigGuardrails.t.sol'],
}

/** Never run: the fork tests need a node, the invariants are random walks, test/e2e a deployed chain. */
const NEVER = ['test/fork/', 'test/invariant/', 'test/e2e/']
/** The gas and size bounds of the optimized build, which fail on the mutation profile's. */
const GAS_BOUNDS = 'Headroom|WholeExitStaysWithinItsGas|fitsTheInitcodeLimit'
/** The gas snapshot's fuzz seed (scripts/snapshots.sh): a fuzzed test draws the same inputs on every mutant. */
const FUZZ_SEED = '0xd0e1'

const RULE_NAMES = 'comparison arithmetic assignment logical negation guard literal return'
/** The rules, as the list above names them. */
export const RULES = RULE_NAMES.split(' ')

// ---------------------------------------------------------------------------------------------------------------------
// Mutants
// ---------------------------------------------------------------------------------------------------------------------

const OPERATORS = [
  '>>>=', '<<=', '>>=', '>>>', '**', '&&', '||', '==', '!=', '<=', '>=', '<<', '>>', '++', '--', '+=', '-=', '*=',
  '/=', '%=', '&=', '|=', '^=', '=>', '->', ':=',
] // prettier-ignore
const SWAPS = {
  comparison: { '<': '<=', '<=': '<', '>': '>=', '>=': '>', '==': '!=', '!=': '==' },
  arithmetic: { '+': '-', '-': '+', '*': '/', '/': '*' },
  assignment: { '+=': '-=', '-=': '+=' },
  logical: { '&&': '||', '||': '&&' },
}
/** Words after which a + or a - is unary. */
const KEYWORDS = new Set('return emit revert if else while for do new delete case'.split(' '))
/** Declarations left alone, from their keyword to their semicolon. */
const DECLARATIONS = new Set(['pragma', 'import', 'event', 'error'])

/**
 * The tokens of a Solidity source, without its comments (NatSpec included) and whitespace:
 * `{ type, text, start, end }`, `type` one of word, number, string and op.
 */
export function tokenize(source) {
  const tokens = []
  const word = /[A-Za-z_$][A-Za-z0-9_$]*/y
  const number = /0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE]-?[0-9_]+)?/y
  let i = 0
  while (i < source.length) {
    const c = source[i]
    if (/\s/.test(c)) {
      i++
    } else if (source.startsWith('//', i)) {
      const end = source.indexOf('\n', i)
      i = end < 0 ? source.length : end
    } else if (source.startsWith('/*', i)) {
      const end = source.indexOf('*/', i + 2)
      i = end < 0 ? source.length : end + 2
    } else if (c === '"' || c === "'") {
      let j = i + 1
      while (j < source.length && source[j] !== c) j += source[j] === '\\' ? 2 : 1
      tokens.push({ type: 'string', text: source.slice(i, j + 1), start: i, end: j + 1 })
      i = j + 1
    } else {
      let type = 'op'
      let length = (OPERATORS.find((op) => source.startsWith(op, i)) ?? c).length
      for (const [kind, pattern] of [
        ['word', word],
        ['number', number],
      ]) {
        pattern.lastIndex = i
        const match = pattern.exec(source)
        if (match) [type, length] = [kind, match[0].length]
      }
      tokens.push({ type, text: source.slice(i, i + length), start: i, end: i + length })
      i += length
    }
  }
  return tokens
}

/** The index of the token closing each bracket, parenthesis and brace (and of the one opening it). */
function pairs(tokens) {
  const match = new Array(tokens.length).fill(-1)
  const open = []
  tokens.forEach((t, i) => {
    if (t.type !== 'op') return
    if ('([{'.includes(t.text)) open.push(i)
    else if (')]}'.includes(t.text) && open.length) {
      const o = open.pop()
      match[o] = i
      match[i] = o
    }
  })
  return match
}

/** The index of the semicolon ending the statement from `i`, over brackets, parentheses and braces. */
function semicolon(tokens, match, i) {
  for (let j = i; j < tokens.length; j++) {
    if (tokens[j].text === ';') return j
    if ('([{'.includes(tokens[j].text) && match[j] > j) j = match[j]
  }
  return tokens.length - 1
}

/** The zero a function returning `type` can return instead, or null if it returns something else. */
function zeroOf(type) {
  if (/^u?int\d*$/.test(type)) return '0'
  if (type === 'bool') return 'false'
  if (type === 'address') return 'address(0)'
  if (/^bytes\d+$/.test(type)) return `${type}(0)`
  return null
}

/** One more than an integer literal, written as it was, or null if it is no literal this rule touches. */
function plusOne(text) {
  if (/^[0-9][0-9_]*$/.test(text)) {
    const next = (BigInt(text.replaceAll('_', '')) + 1n).toString()
    return text.includes('_') ? next.replace(/\B(?=(\d{3})+(?!\d))/g, '_') : next
  }
  const hex = /^0[xX]([0-9a-fA-F_]+)$/.exec(text)?.[1].replaceAll('_', '')
  if (hex && hex.length <= 4) return `0x${(BigInt(`0x${hex}`) + 1n).toString(16)}`
  return null
}

/** The line and column (from 1) of each offset of `source`. */
function locator(source) {
  const starts = [0]
  for (let i = 0; i < source.length; i++) if (source[i] === '\n') starts.push(i + 1)
  return (offset) => {
    let [lo, hi] = [0, starts.length - 1]
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (starts[mid] <= offset) lo = mid
      else hi = mid - 1
    }
    return { line: lo + 1, col: offset - starts[lo] + 1 }
  }
}

/**
 * The mutants of `source`, the contents of `file` (from the repository's root), in the order of their place in it:
 * `{ id, file, rule, line, col, start, end, from, to }`, the text from `start` to `end` replaced by `to`.
 */
export function mutantsOf(file, source) {
  const tokens = tokenize(source)
  const match = pairs(tokens)
  const locate = locator(source)
  const skipped = new Array(tokens.length).fill(false)
  const returns = new Array(tokens.length).fill(null) // the zero each token's function can return instead
  const atStatement = (i) => i === 0 || [';', '{', '}'].includes(tokens[i - 1].text)

  tokens.forEach((t, i) => {
    if (t.type !== 'word' || !atStatement(i)) return
    if (DECLARATIONS.has(t.text)) {
      for (let j = i; j <= semicolon(tokens, match, i); j++) skipped[j] = true
    } else if (t.text === 'function') {
      // its signature up to its body: a single return value of a simple type, and the body it is returned from
      let zero = null
      for (let j = i + 1; j < tokens.length; j++) {
        const u = tokens[j]
        if (u.text === ';') break
        if (u.text === 'returns' && tokens[j + 1]?.text === '(') {
          const list = tokens.slice(j + 2, match[j + 1])
          const single = !list.some((v) => v.text === ',' || v.text === '[')
          zero = single && list[0] ? zeroOf(list[0].text) : null
          j = match[j + 1]
        } else if (u.text === '(' && match[j] > j) {
          j = match[j]
        } else if (u.text === '{') {
          for (let k = j; k <= match[j]; k++) returns[k] = zero
          break
        }
      }
    }
  })

  const mutants = []
  const add = (rule, start, end, to) => {
    const { line, col } = locate(start)
    mutants.push({ rule, line, col, start, end, from: source.slice(start, end), to, file })
  }
  tokens.forEach((t, i) => {
    if (skipped[i]) return
    const previous = tokens[i - 1]
    if (t.type === 'op') {
      if (SWAPS.comparison[t.text]) add('comparison', t.start, t.end, SWAPS.comparison[t.text])
      if (SWAPS.assignment[t.text]) add('assignment', t.start, t.end, SWAPS.assignment[t.text])
      if (SWAPS.logical[t.text]) add('logical', t.start, t.end, SWAPS.logical[t.text])
      if (t.text === '!') add('negation', t.start, t.end, '')
      const binary =
        previous &&
        (previous.type === 'number' ||
          (previous.type === 'word' && !KEYWORDS.has(previous.text)) ||
          [')', ']'].includes(previous.text))
      if (SWAPS.arithmetic[t.text] && binary)
        add('arithmetic', t.start, t.end, SWAPS.arithmetic[t.text])
    } else if (t.type === 'number') {
      const to = plusOne(t.text)
      if (to !== null) add('literal', t.start, t.end, to)
    } else if (t.type === 'word') {
      // a guard: `if (...) revert E(...);`, or a revert alone; removed, its line breaks kept
      let end = -1
      if (
        t.text === 'if' &&
        tokens[i + 1]?.text === '(' &&
        tokens[match[i + 1] + 1]?.text === 'revert'
      ) {
        end = semicolon(tokens, match, match[i + 1] + 1)
      } else if (t.text === 'revert' && atStatement(i)) {
        end = semicolon(tokens, match, i)
      }
      if (end >= 0) {
        add(
          'guard',
          t.start,
          tokens[end].end,
          source.slice(t.start, tokens[end].end).replace(/[^\n]/g, ''),
        )
      }
      if (t.text === 'return' && returns[i] !== null && tokens[i + 1]?.text !== ';') {
        const last = semicolon(tokens, match, i) - 1
        const [start, stop] = [tokens[i + 1].start, tokens[last].end]
        if (source.slice(start, stop) !== returns[i]) add('return', start, stop, returns[i])
      }
    }
  })

  const base = path.basename(file)
  const seen = new Map()
  return mutants
    .sort((a, b) => a.start - b.start || RULES.indexOf(a.rule) - RULES.indexOf(b.rule))
    .map((m) => {
      const id = `${base}:${m.line}:${m.col}`
      const n = (seen.get(id) ?? 0) + 1
      seen.set(id, n)
      return { id: n === 1 ? id : `${id}/${n}`, ...m }
    })
}

/** The source with `mutant` applied. */
export const apply = (source, mutant) =>
  source.slice(0, mutant.start) + mutant.to + source.slice(mutant.end)

/** A mutant in one line: `id rule: from -> to`, whitespace folded. */
export function describe(m) {
  const fold = (text) => text.replace(/\s+/g, ' ').trim()
  const to = m.rule === 'guard' ? '(removed)' : m.rule === 'negation' ? '(removed)' : fold(m.to)
  return `${m.id} ${m.rule}: ${fold(m.from)} -> ${to}`
}

// ---------------------------------------------------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------------------------------------------------

/** A deterministic generator of numbers in [0, 1) (mulberry32). */
function random(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = Math.imul(a ^ (a >>> 15), a | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const seedOf = (seed, file) =>
  parseInt(createHash('sha256').update(`${seed}:${file}`).digest('hex').slice(0, 8), 16)

/**
 * `n` of `mutants`, drawn with `seed`: each file's share in proportion to its mutants times its weight (`weights`, by
 * file or by base name, 1 by default), the rounding going to the largest remainders; within a file, the first of its
 * mutants shuffled by a generator seeded with `seed` and the file. Back in the order of their place in the files.
 */
export function sample(mutants, n, seed, weights = {}) {
  const files = [...new Set(mutants.map((m) => m.file))]
  const of = files.map((f) => mutants.filter((m) => m.file === f))
  const mass = files.map((f, i) => of[i].length * (weights[f] ?? weights[path.basename(f)] ?? 1))
  const total = mass.reduce((a, b) => a + b, 0)
  const wanted = Math.min(n, total > 0 ? mutants.length : 0)
  const exact = mass.map((m) => (total > 0 ? (wanted * m) / total : 0))
  const take = exact.map((e, i) => Math.min(Math.floor(e), of[i].length))
  const order = files
    .map((_, i) => i)
    .sort((a, b) => exact[b] - Math.floor(exact[b]) - (exact[a] - Math.floor(exact[a])) || a - b)
  let left = wanted - take.reduce((a, b) => a + b, 0)
  while (left > 0) {
    let given = false
    for (const i of order) {
      if (left > 0 && take[i] < of[i].length && mass[i] > 0) {
        take[i]++
        left--
        given = true
      }
    }
    if (!given) break
  }
  return files.flatMap((f, i) => {
    const next = random(seedOf(seed, f))
    const shuffled = [...of[i]]
    for (let j = shuffled.length - 1; j > 0; j--) {
      const k = Math.floor(next() * (j + 1))
      ;[shuffled[j], shuffled[k]] = [shuffled[k], shuffled[j]]
    }
    return shuffled.slice(0, take[i]).sort((a, b) => a.start - b.start)
  })
}

// ---------------------------------------------------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------------------------------------------------

/** The file being mutated, with its original contents and its journal, while a mutant is applied. */
let inflight = null
/** The forges running. */
const children = new Set()
/** Set by a signal: no forge starts any more. */
let interrupted = false

/** The build folders of a forge (out/mutation/<name>, cache/mutation/<name>). */
const buildOf = (name) => ({
  out: path.join(CONTRACTS, 'out', 'mutation', name),
  cache: path.join(STATE, name),
})

/** Puts the file being mutated back as it was, if a mutant is applied; idempotent, synchronous (for exit handlers). */
function restore() {
  if (!inflight) return
  fs.writeFileSync(inflight.path, inflight.original)
  if (fs.readFileSync(inflight.path, 'utf8') !== inflight.original) {
    throw new Error(`could not restore ${inflight.path}`)
  }
  fs.rmSync(JOURNAL, { force: true })
  inflight = null
}

/**
 * A run killed outright left a mutant in its file, and maybe forges running on it: stops them and puts the original
 * back, from the journal. A forge stopped there may have been writing its build: the builds go, all of them.
 */
function recover() {
  if (!fs.existsSync(JOURNAL)) return
  const journal = JSON.parse(fs.readFileSync(JOURNAL, 'utf8'))
  let stopped = false
  for (const pid of journal.forges ?? []) {
    try {
      const command = execFileSync('ps', ['-o', 'comm=', '-p', String(pid)], { encoding: 'utf8' })
      if (command.trim().endsWith('forge')) {
        process.kill(-pid, 'SIGKILL')
        stopped = true
      }
    } catch {
      // gone already
    }
  }
  if (stopped) {
    execFileSync('sleep', ['1']) // their exit
    fs.rmSync(path.join(CONTRACTS, 'out', 'mutation'), { recursive: true, force: true })
    // the forges' cache folders (own, 1, 2…, or <profile>-own…), not the reports one may keep there
    for (const entry of fs.readdirSync(STATE, { withFileTypes: true })) {
      if (entry.isDirectory() && /^([\w.]+-)?(own|\d+)$/.test(entry.name)) {
        fs.rmSync(path.join(STATE, entry.name), { recursive: true, force: true })
      }
    }
  }
  const file = path.join(CONTRACTS, journal.file)
  if (fs.readFileSync(file, 'utf8') !== journal.original) {
    fs.writeFileSync(file, journal.original)
    console.error(
      `${journal.file}: restored from ${path.relative(ROOT, JOURNAL)} (mutant ${journal.mutant} was left)`,
    )
  }
  fs.rmSync(JOURNAL)
}

/** Applies `mutant` to its file, after writing the journal that can undo it. */
function applyMutant(mutant, original) {
  const file = path.join(CONTRACTS, mutant.file)
  fs.mkdirSync(STATE, { recursive: true })
  const journal = { file: mutant.file, mutant: mutant.id, original, forges: [] }
  fs.writeFileSync(JOURNAL, JSON.stringify(journal))
  inflight = { path: file, original, journal }
  fs.writeFileSync(file, apply(original, mutant))
}

/**
 * Stops a forge, and the solc it started. Between solc's end and "Compiler run successful!", forge writes its
 * artifacts, then its cache: stopped then, its build could hold a mutant's artifact that its cache takes for the
 * source's, so its build folders go once it has exited, and the next run builds them again.
 */
function stop(child) {
  child.stopped = true
  if (child.phase === 'writing') child.discard = true
  try {
    process.kill(-child.pid, 'SIGKILL')
  } catch {
    // gone already
  }
}

/** Stops every forge running; resolves once they have all exited. */
function stopAll() {
  const exits = [...children].map((child) => child.exited)
  for (const child of children) stop(child)
  return Promise.all(exits)
}

/** The test files forge may run: those under test/ ending in .t.sol, but for those it never runs. */
function testFiles() {
  const found = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(CONTRACTS, dir), { withFileTypes: true })) {
      const file = `${dir}/${entry.name}`
      if (entry.isDirectory()) walk(file)
      else if (file.endsWith('.t.sol')) found.push(file)
    }
  }
  walk('test')
  return found.filter((f) => !NEVER.some((never) => f.startsWith(never))).sort()
}

/**
 * The forges a mutant of `file` runs its tests in: one for the file's own tests (OWN), then the others shared out
 * between `jobs` forges, each file to the forge with the fewest bytes so far (the bytes stand for the time to compile):
 * test/audit's first, which take the longest to run, then the largest. Every file is shared out, and a file's own tests
 * left out after: each forge keeps the same tests, and their builds, whatever file is mutated.
 */
export function groups(file, jobs, files = testFiles()) {
  const own = OWN[file] ?? []
  const shares = Array.from({ length: jobs }, (_, k) => ({ name: `${k + 1}`, paths: [], bytes: 0 }))
  const sized = files.map((f) => [f, fs.statSync(path.join(CONTRACTS, f)).size])
  const audit = (f) => (f.startsWith('test/audit/') ? 0 : 1)
  const order = (a, b) => audit(a[0]) - audit(b[0]) || b[1] - a[1] || a[0].localeCompare(b[0])
  for (const [f, bytes] of sized.sort(order)) {
    const lightest = shares.reduce((a, b) => (b.bytes < a.bytes ? b : a))
    lightest.paths.push(f)
    lightest.bytes += bytes
  }
  const forges = own.length ? [{ name: 'own', paths: own }] : []
  for (const share of shares) {
    const paths = share.paths.filter((p) => !own.includes(p)).sort()
    if (paths.length) forges.push({ name: share.name, paths })
  }
  return forges
}

/** forge's glob of several paths. */
const anyOf = (paths) => (paths.length === 1 ? paths[0] : `{${paths.join(',')}}`)

/**
 * Runs `forge test` on a group's tests, in the group's own build folders: its exit code, its output (the end of it),
 * whether it timed out or was stopped, its seconds.
 */
function forge(group, { profile, timeout }) {
  const name = profile === 'mutation' ? group.name : `${profile}-${group.name}`
  const { out, cache } = buildOf(name)
  // a fuzz failure forge persists is replayed first in later runs: each run starts without any
  const persisted = path.join(cache, 'fuzz')
  fs.rmSync(persisted, { recursive: true, force: true })
  const argv = ['test', '--offline', '--fail-fast', '--no-dynamic-test-linking']
  argv.push('--fuzz-seed', FUZZ_SEED, '--match-path', anyOf(group.paths))
  if (profile !== 'default') argv.push('--no-match-test', GAS_BOUNDS)
  const env = {
    ...process.env,
    FOUNDRY_PROFILE: profile,
    FOUNDRY_OUT: out,
    FOUNDRY_CACHE_PATH: cache,
    FOUNDRY_FUZZ_FAILURE_PERSIST_DIR: persisted,
    FOUNDRY_TEST_FAILURES_FILE: path.join(cache, 'test-failures'),
  }
  const started = Date.now()
  if (interrupted) return Promise.resolve({ code: null, output: '', stopped: true, seconds: 0 })
  return new Promise((resolve, reject) => {
    // in a process group of its own, which stop ends whole; the journal names it, for a run killed outright
    const child = spawn('forge', argv, {
      cwd: CONTRACTS,
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    child.phase = 'compiling'
    child.exited = new Promise((exited) => child.once('close', exited))
    children.add(child)
    if (inflight && child.pid) {
      inflight.journal.forges.push(child.pid)
      fs.writeFileSync(JOURNAL, JSON.stringify(inflight.journal))
    }
    let output = ''
    const keep = (chunk) => {
      output += chunk
      if (output.length > 4_000_000) output = output.slice(-2_000_000)
      if (child.phase === 'tests') return
      const tail = output.slice(-4096)
      if (/Compiler run (successful|failed)|No files changed/.test(tail)) child.phase = 'tests'
      else if (/Solc [\d.]+ finished/.test(tail)) child.phase = 'writing'
    }
    child.stdout.on('data', keep)
    child.stderr.on('data', keep)
    let timedOut = false
    const timer = setTimeout(() => {
      timedOut = true
      stop(child)
    }, timeout * 1000)
    child.on('error', (error) => {
      clearTimeout(timer)
      children.delete(child)
      reject(error)
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      children.delete(child)
      if (child.discard) {
        fs.rmSync(out, { recursive: true, force: true })
        fs.rmSync(cache, { recursive: true, force: true })
      }
      // its last words, for a verdict to check: cache/mutation/<forge>/forge.log
      fs.mkdirSync(cache, { recursive: true })
      fs.writeFileSync(path.join(cache, 'forge.log'), `forge ${argv.join(' ')}\n${output}`)
      const seconds = (Date.now() - started) / 1000
      resolve({ code, output, timedOut, stopped: Boolean(child.stopped) && !timedOut, seconds })
    })
  })
}

/** What a forge run says of a mutant: killed (by which test), survived, did not compile, timed out, or an error. */
export function verdict({ code, output, timedOut }) {
  if (timedOut) return { status: 'timeout' }
  if (/Compiler run failed/.test(output)) {
    const error = /^Error \(\d+\):.*$/m.exec(output)?.[0] ?? /^Error: .*$/m.exec(output)?.[0]
    return { status: 'nocompile', detail: error }
  }
  const failing = /Encountered \d+ failing tests? in (\S+)\n\[FAIL.*\] (\w+)\(/.exec(output)
  const first = /^\[FAIL.*\] (\w+)\(/m.exec(output)
  if (failing || first) {
    const name = failing ? `${failing[1].split(':').pop()}.${failing[2]}` : first[1]
    return { status: 'killed', by: name }
  }
  if (code === 0) {
    if (!/Ran \d+ tests? for/.test(output)) return { status: 'error', detail: 'no test ran' }
    return { status: 'survived' }
  }
  return { status: 'error', detail: output.trim().split('\n').slice(-5).join(' | ') }
}

/**
 * Runs `forges` at once: the first that does not pass (a test failed, it did not compile, it timed out) stops the
 * others and gives the verdict, with the name of its group; if all pass, the mutant survived.
 */
async function runGroups(forges, options) {
  const started = Date.now()
  const timings = {}
  let decided = null
  await Promise.all(
    forges.map(async (group) => {
      const run = await forge(group, options)
      timings[group.name] = Math.round(run.seconds)
      if (decided || run.stopped) return
      const result = verdict(run)
      if (result.status !== 'survived') {
        decided = { ...result, stage: group.name }
        stopAll()
      }
    }),
  )
  // stopped by a signal before any verdict: no status, the mutant did not run
  const result = decided ?? (interrupted ? {} : { status: 'survived', stage: 'all' })
  return { ...result, timings, seconds: Math.round((Date.now() - started) / 1000) }
}

/** Runs one mutant, its file restored after. */
async function runMutant(mutant, original, options) {
  applyMutant(mutant, original)
  try {
    return await runGroups(groups(mutant.file, options.jobs), options)
  } finally {
    restore()
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------------------------------------------------

const STATUSES = ['killed', 'survived', 'nocompile', 'timeout', 'error']

/** The counts of each status, per file and for all: `{ file: { generated, run, killed, ... } }`. */
export function tally(generated, results) {
  const files = [...new Set(generated.map((m) => m.file))]
  const row = (match) => {
    const counts = { generated: generated.filter(match).length, run: results.filter(match).length }
    for (const s of STATUSES) counts[s] = results.filter((r) => match(r) && r.status === s).length
    return counts
  }
  return Object.fromEntries([
    ...files.map((f) => [f, row((m) => m.file === f)]),
    ['all', row(() => true)],
  ])
}

const minutes = (seconds) =>
  seconds >= 3600
    ? `${Math.floor(seconds / 3600)} h ${Math.round((seconds % 3600) / 60)} min`
    : `${Math.round(seconds / 60)} min`

/** The summary's head: what ran, the counts per file, the share killed and the time it took. */
export function summaryHead(report) {
  const { meta, counts, mutants } = report
  const headings = ['mutants', 'run', 'killed', 'survived', 'no compile', 'timeout', 'error']
  const lines = [
    `Mutation testing of the contracts, ${meta.date}: profile ${meta.profile}, ${meta.selection}.`,
    '',
    `${'file'.padEnd(28)}${headings.map((h) => h.padStart(11)).join('')}`,
  ]
  for (const [file, c] of Object.entries(counts)) {
    const cells = [c.generated, c.run, c.killed, c.survived, c.nocompile, c.timeout, c.error]
    lines.push(`${file.padEnd(28)}${cells.map((n) => String(n).padStart(11)).join('')}`)
  }
  const all = counts.all
  const detected = all.killed + all.timeout
  const compiled = detected + all.survived
  if (compiled) {
    const share = ((100 * detected) / compiled).toFixed(1)
    lines.push('', `Killed: ${share}% of the mutants that compiled.`)
  }
  const done = mutants.filter((m) => m.seconds !== undefined)
  if (done.length) {
    const total = done.reduce((a, m) => a + m.seconds, 0)
    const average = (list) =>
      `${Math.round(list.reduce((a, m) => a + m.seconds, 0) / Math.max(list.length, 1))} s (${list.length})`
    const own = done.filter((m) => m.stage === 'own')
    const others = done.filter((m) => m.stage !== 'own' && m.stage !== 'all')
    const survivors = done.filter((m) => m.stage === 'all')
    lines.push(
      `Time: ${minutes(total)}, ${Math.round(total / done.length)} s a mutant: ${average(own)} when its file's ` +
        `own tests kill it, ${average(others)} when others do, ${average(survivors)} when it survives.`,
    )
  }
  return lines.join('\n')
}

/** The summary, for reading: the counts, the survivors, the mutants that did not compile, those killed and by whom. */
export function summary(report) {
  const lines = [summaryHead(report)]
  const section = (title, status, line) => {
    const list = report.mutants.filter((m) => m.status === status)
    if (!list.length) return
    lines.push('', title)
    for (const m of list) lines.push(`  ${line(m)}`)
  }
  section('Survived', 'survived', (m) => `${describe(m)}\n      ${m.code}`)
  section('Timed out', 'timeout', (m) => describe(m))
  section('Errors', 'error', (m) => `${describe(m)}: ${m.detail}`)
  section('Did not compile', 'nocompile', (m) => `${describe(m)}: ${m.detail}`)
  section('Killed', 'killed', (m) => {
    const where = m.stage === 'own' ? "its file's own tests" : `forge ${m.stage}`
    return `${describe(m)}  [${m.by}, ${where}, ${m.seconds} s]`
  })
  section('Not run', undefined, (m) => describe(m))
  return `${lines.join('\n')}\n`
}

function writeReport(directory, report) {
  fs.mkdirSync(directory, { recursive: true })
  fs.writeFileSync(path.join(directory, 'report.json'), `${JSON.stringify(report, null, 2)}\n`)
  fs.writeFileSync(path.join(directory, 'summary.txt'), summary(report))
}

// ---------------------------------------------------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------------------------------------------------

/** A file as given: from the repository's root, or its base name among the default files. */
function resolveFile(name) {
  const relative = name.replace(/^\.\//, '').replace(/^contracts\//, '')
  if (fs.existsSync(path.join(CONTRACTS, relative))) return relative
  const known = FILES.find((f) => path.basename(f) === name)
  if (known) return known
  throw new Error(`${name}: no such file in the repository`)
}

const list = (value) =>
  (value ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean)

export async function main(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      file: { type: 'string', multiple: true },
      line: { type: 'string' },
      id: { type: 'string', multiple: true },
      rule: { type: 'string' },
      sample: { type: 'string' },
      seed: { type: 'string', default: '1' },
      weight: { type: 'string' },
      jobs: { type: 'string', default: '3' },
      list: { type: 'boolean', default: false },
      report: { type: 'string', default: path.relative(ROOT, STATE) },
      profile: { type: 'string', default: 'mutation' },
      timeout: { type: 'string', default: '900' },
      'no-baseline': { type: 'boolean', default: false },
    },
  })
  recover()

  const ids = (values.id ?? []).flatMap(list)
  const named = [...(values.file ?? []), ...positionals]
  const fromIds = ids.map((id) => id.split(':')[0])
  const chosen = named.length ? named : fromIds.length ? fromIds : FILES
  const files = [...new Set(chosen.map(resolveFile))]
  const sources = Object.fromEntries(
    files.map((f) => [f, fs.readFileSync(path.join(CONTRACTS, f), 'utf8')]),
  )
  const generated = files.flatMap((f) => mutantsOf(f, sources[f]))

  let selected = generated
  if (values.line) {
    const [from, to = from] = values.line.split('-').map(Number)
    selected = selected.filter((m) => m.line >= from && m.line <= to)
  }
  if (values.rule) {
    const rules = list(values.rule)
    const unknown = rules.filter((r) => !RULES.includes(r))
    if (unknown.length)
      throw new Error(`unknown rules: ${unknown.join(', ')} (${RULES.join(', ')})`)
    selected = selected.filter((m) => rules.includes(m.rule))
  }
  if (ids.length) {
    const missing = ids.filter((id) => !generated.some((m) => m.id === id))
    if (missing.length) throw new Error(`no such mutants: ${missing.join(', ')} (see --list)`)
    selected = selected.filter((m) => ids.includes(m.id))
  }
  const weights = Object.fromEntries(list(values.weight).map((w) => w.split('=')))
  for (const key of Object.keys(weights)) weights[key] = Number(weights[key])
  if (values.sample) {
    selected = sample(selected, Number(values.sample), Number(values.seed), weights)
  }

  if (values.list) {
    for (const m of selected) console.log(describe(m))
    for (const [file, c] of Object.entries(tally(generated, selected))) {
      console.log(`${file}: ${c.run} of ${c.generated}`)
    }
    return
  }

  if (!selected.length) {
    console.log('no mutant to run')
    return
  }
  const options = {
    profile: values.profile,
    jobs: Number(values.jobs),
    timeout: Number(values.timeout),
  }
  for (const option of ['jobs', 'timeout']) {
    if (!Number.isInteger(options[option]) || options[option] < 1) {
      throw new Error(`--${option}: a whole number, 1 at least`)
    }
  }
  const drawn = values.sample
    ? `, drawn with seed ${values.seed}${values.weight ? ` and weights ${values.weight}` : ''}`
    : ''
  const selection = `${selected.length} mutants of ${generated.length}${drawn}`
  const lineOf = (m) => sources[m.file].split('\n')[m.line - 1].trim()
  const report = {
    meta: {
      date: `${new Date().toISOString().replace('T', ' ').slice(0, 16)} UTC`,
      profile: options.profile,
      selection,
      jobs: options.jobs,
      fuzzSeed: FUZZ_SEED,
      sources: Object.fromEntries(
        files.map((f) => [f, createHash('sha256').update(sources[f]).digest('hex').slice(0, 16)]),
      ),
      command: `node scripts/mutation.mjs ${argv.join(' ')}`.trim(),
    },
    counts: tally(generated, []),
    mutants: selected.map((m) => ({ ...m, code: lineOf(m) })),
  }
  const directory = path.resolve(ROOT, values.report)
  const shown = path.relative(ROOT, directory).startsWith('..')
    ? directory
    : path.relative(ROOT, directory)
  const save = () => {
    report.counts = tally(
      generated,
      report.mutants.filter((m) => m.status),
    )
    writeReport(directory, report)
  }

  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, async () => {
      if (interrupted) return
      interrupted = true
      // the forges' exit first (a build they were writing goes), then the source back
      await Promise.race([stopAll(), new Promise((done) => setTimeout(done, 10_000))])
      restore()
      save()
      console.error(`\n${signal}: stopped; the sources are as they were, the report has what ran`)
      process.exit(130)
    })
  }
  process.on('exit', restore)

  console.log(`${selection}; report in ${shown}/`)
  if (!values['no-baseline']) {
    // every test, unmutated (in the forges of the first mutant, which then find their builds): a failure here would
    // kill every mutant
    const result = await runGroups(groups(selected[0].file, options.jobs), options)
    if (interrupted) return
    const passes = result.status === 'survived'
    console.log(`unmutated: ${passes ? 'every test passes' : result.status} (${result.seconds} s)`)
    if (!passes) {
      console.error(result.by ?? result.detail)
      process.exitCode = 1
      return
    }
  }

  for (const [n, m] of report.mutants.entries()) {
    const result = await runMutant(m, sources[m.file], options)
    if (interrupted) return
    Object.assign(m, result)
    const how = m.status === 'killed' ? ` by ${m.by}` : m.detail ? `: ${m.detail}` : ''
    const where = m.stage === 'all' ? '' : `, forge ${m.stage}`
    console.log(
      `[${n + 1}/${report.mutants.length}] ${describe(m)}: ${m.status}${how} (${m.seconds} s${where})`,
    )
    save()
  }
  save()
  for (const f of files) {
    if (fs.readFileSync(path.join(CONTRACTS, f), 'utf8') !== sources[f]) {
      throw new Error(`${f} was not restored`)
    }
  }
  console.log(`\n${summaryHead(report)}\nThe mutants, survivors first: ${shown}/summary.txt`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(async (error) => {
    interrupted = true
    await stopAll()
    restore()
    console.error(error.message ?? error)
    process.exit(1)
  })
}
