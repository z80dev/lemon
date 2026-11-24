import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Docs cite source code in three ways that ordinary link checking cannot
// validate: `file.ex:N` line citations, telemetry catalog rows naming the
// function that emits an event, and repository paths inside shell command
// blocks. Each check reads the repository checkout; none needs dependencies.

const TELEMETRY_DOC = 'docs/telemetry.md'
// A telemetry call, or a local `emit([...])` pass-through given a literal event.
const TELEMETRY_CALL = /:telemetry\.(?:execute|span)\(|\bTelemetry\.(?:emit|span)\(|(?<![\w.])emit\(\s*\[/
const LINK = /\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)/g
const FUNCTION_REF = /^`(?:[A-Z][\w.]*\.)?([a-z_]\w*[?!]?)\/(\d+)`$/
const DEF = /^(\s*)(?:def|defp|defmacro|defmacrop)\s+([a-z_]\w*[?!]?)/
const SHELL_FENCE = /^```(?:bash|sh|shell|zsh|console)\s*$/
const REPO_ROOTS = ['apps', 'bin', 'clients', 'config', 'docs', 'examples', 'rel', 'scripts']
// Subproject directories; checked only relative to a directory the block enters.
const SUBPROJECT_ROOTS = ['lib', 'priv', 'src', 'test']
const CWD_FLAG = /(?:^|\s)(?:cd|--cwd|-C|--prefix|--dir)\s+([\w./-]+)/g

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length
}

// Resolve a markdown link target relative to the citing page; null for
// external, anchor-only or out-of-repository links.
export function repoTarget(href, docPath) {
  if (/^(?:[a-z][a-z\d+.-]*:|#|\/)/i.test(href)) return null
  const [pathname, fragment = ''] = href.split('#', 2)
  const target = normalize(join(dirname(docPath), decodeURIComponent(pathname)))
  return target.startsWith('..') ? null : { path: target, fragment }
}

// Accepted arities of a function head: `\\` defaults make trailing
// parameters optional. `rest` starts just after the function name.
function headArity(rest) {
  if (!rest.startsWith('(')) return [0, 0]
  const params = []
  let depth = 0
  let quote = null
  let current = ''
  for (const char of rest.slice(1)) {
    if (quote) quote = char === quote ? null : quote
    else if (char === '"' || char === "'") quote = char
    else if ('([{'.includes(char)) depth++
    else if (')]}'.includes(char)) {
      if (depth === 0) break
      depth--
    } else if (char === ',' && depth === 0) {
      params.push(current)
      current = ''
      continue
    }
    current += char
  }
  if (current.trim()) params.push(current)
  return [params.filter(param => !param.includes('\\\\')).length, params.length]
}

// Function clauses (1-based, inclusive line ranges and accepted arities) keyed
// by name. A clause ends at the next non-blank line indented no deeper than its
// `def`.
export function functionClauses(source) {
  const lines = source.split('\n')
  const clauses = new Map()
  lines.forEach((line, index) => {
    const match = line.match(DEF)
    if (!match) return
    const indent = match[1].length
    let end = index
    for (let next = index + 1; next < lines.length; next++) {
      const text = lines[next]
      if (!text.trim()) continue
      if (text.length - text.trimStart().length <= indent) {
        end = text.trim() === 'end' ? next : end
        break
      }
      end = next
    }
    const head = lines.slice(index, end + 1).join('\n').slice(match.index + match[0].length)
    const clause = { start: index + 1, end: end + 1, arity: headArity(head) }
    clauses.set(match[2], [...(clauses.get(match[2]) ?? []), clause])
  })
  return clauses
}

// Clauses of `name/arity` in `source`, or an issue string when none exist.
function citedFunction(source, path, name, arity) {
  const clauses = (functionClauses(source).get(name) ?? [])
    .filter(({ arity: [min, max] }) => min <= arity && arity <= max)
  return clauses.length ? clauses : `\`${name}/${arity}\` is not defined in ${path}`
}

export function parseEvent(cell) {
  const match = cell.trim().match(/^`\[(:[\w]+(?:,\s*(?::[\w]+|<\w+>))*)\]`$/)
  return match ? match[1].split(/,\s*/) : null
}

function squash(text) {
  return text.replace(/\s+/g, ' ').replace(/\[ /g, '[').replace(/ \]/g, ']')
}

// Inline `@prefix ++ [:leaf]` using the module's `@prefix [:a, :b]` attribute.
function expandAttributes(flat, moduleSource) {
  const attributes = new Map([...squash(moduleSource).matchAll(/@(\w+) \[(:\w+(?:, :\w+)*)\]/g)]
    .map(([, name, list]) => [name, list]))
  return flat.replace(/@(\w+) \+\+ \[/g, (match, name) => attributes.has(name) ? `[${attributes.get(name)}, ` : match)
}

// True when `body` makes a telemetry call and names `event`: the literal
// event list, or its prefix with a runtime final segment whose documented atom
// appears in the module.
export function emitsEvent(body, moduleSource, event) {
  if (!TELEMETRY_CALL.test(body)) return false
  const flat = expandAttributes(squash(body), moduleSource)
  if (flat.includes(`[${event.join(', ')}]`)) return true
  const prefix = event.slice(0, -1).join(', ')
  const last = event[event.length - 1]
  if (!flat.includes(`[${prefix}, `) ||
    !new RegExp(`\\[${prefix.replace(/[[\]]/g, '\\$&')}, [a-z_]\\w*\\]`).test(flat)) return false
  return last.startsWith('<') || new RegExp(`${last}\\b`).test(moduleSource)
}

function tableRows(markdown) {
  const rows = []
  let header = null
  markdown.split('\n').forEach((line, index) => {
    if (!line.startsWith('|')) {
      header = null
      return
    }
    const cells = line.slice(1, line.endsWith('|') ? -1 : undefined).split(/(?<!\\)\|/).map(cell => cell.trim())
    if (!header) header = cells
    else if (!/^:?-+/.test(cells[0])) rows.push({ header, cells, line: index + 1, text: line })
  })
  return rows
}

function sourceLinks(text, docPath) {
  return [...text.matchAll(LINK)].flatMap(match => {
    const target = repoTarget(match[2], docPath)
    if (!target || !/\.exs?$/.test(target.path)) return []
    const fun = match[1].match(FUNCTION_REF)
    return [{ label: match[1], index: match.index, ...target, ...(fun && { name: fun[1], arity: Number(fun[2]) }) }]
  })
}

// Every row of an `Event` table in the telemetry catalog links, to its module
// source, a `function/arity` whose body emits that event.
export function telemetryRowIssues(markdown, docPath, read) {
  const issues = []
  for (const row of tableRows(markdown)) {
    if (row.header[0] !== 'Event') continue
    const event = parseEvent(row.cells[0])
    const where = `${docPath}:${row.line}`
    if (!event) {
      issues.push(`${where}: event cell is not a single event list: ${row.cells[0]}`)
      continue
    }
    const named = sourceLinks(row.text, docPath).filter(link => link.name)
    const emits = named.some(({ path, name, arity }) => {
      const source = read(path)
      const clauses = source === null ? [] : citedFunction(source, path, name, arity)
      if (typeof clauses === 'string') return false
      const lines = source.split('\n')
      return clauses.some(({ start, end }) => emitsEvent(lines.slice(start - 1, end).join('\n'), source, event))
    })
    if (named.length === 0) issues.push(`${where}: [${event.join(', ')}] names no emitting function link`)
    else if (!emits) issues.push(`${where}: no linked function emits [${event.join(', ')}]`)
  }
  return issues
}

function citedLines(label, fragment) {
  const anchor = fragment.match(/^L(\d+)(?:-L?(\d+))?$/)
  if (anchor) return anchor.slice(1).filter(Boolean).map(Number)
  const text = label.match(/^`[^`]*\.exs?:([\d,\s-]+)`$/)
  return text ? text[1].split(/[,\s-]+/).filter(Boolean).map(Number) : []
}

// Links to Elixir source must name an existing file; a `function/arity` label
// must be defined there; `file.ex:N` and `#LN` citations must name an existing
// line, and in the telemetry catalog land within five lines of a telemetry call.
export function sourceCitationIssues(markdown, docPath, read) {
  const issues = []
  for (const link of sourceLinks(markdown, docPath)) {
    const where = `${docPath}:${lineOf(markdown, link.index)}`
    const source = read(link.path)
    if (source === null) {
      issues.push(`${where}: cited file does not exist: ${link.path}`)
      continue
    }
    if (link.name) {
      const clauses = citedFunction(source, link.path, link.name, link.arity)
      if (typeof clauses === 'string') issues.push(`${where}: ${clauses}`)
    }
    const sourceLines = source.split('\n')
    for (const line of citedLines(link.label, link.fragment)) {
      if (line < 1 || line > sourceLines.length) {
        issues.push(`${where}: ${link.path} has no line ${line} (${sourceLines.length} lines)`)
      } else if (docPath === TELEMETRY_DOC &&
        !sourceLines.slice(Math.max(0, line - 6), line + 5).some(text => TELEMETRY_CALL.test(text))) {
        issues.push(`${where}: ${link.path}:${line} is not within 5 lines of a telemetry call`)
      }
    }
  }
  return issues
}

function stripComment(line) {
  let quote = null
  for (let index = 0; index < line.length; index++) {
    const char = line[index]
    if (quote) quote = char === quote ? null : quote
    else if (char === '"' || char === "'") quote = char
    else if (char === '#' && (index === 0 || /\s/.test(line[index - 1]))) return line.slice(0, index)
  }
  return line
}

// Repository paths in shell blocks must exist, relative to the repository root
// or a directory the block changes into. Placeholders (`<app>`, `$VAR`, globs),
// option values (`@file:`, `--flag=`) and gitignored build outputs are skipped.
export function commandPathIssues(markdown, docPath, exists, ignored = () => false) {
  const issues = []
  const lines = markdown.split('\n')
  for (let index = 0; index < lines.length; index++) {
    if (!SHELL_FENCE.test(lines[index])) continue
    const start = index
    const block = []
    while (++index < lines.length && !lines[index].startsWith('```')) block.push(stripComment(lines[index]))
    const text = block.join('\n')
    const bases = ['', ...[...text.matchAll(CWD_FLAG)].map(match => match[1])]
    for (const [offset, line] of block.entries()) {
      for (const match of line.matchAll(/(?<![\w$/.:=@<>{}-])([\w.-]+\/[^\s'"`;|&()]*)/g)) {
        const path = match[1].replace(/[.,:]+$/, '').replace(/\/$/, '')
        const top = path.split('/')[0]
        const candidates = REPO_ROOTS.includes(top) ? bases : SUBPROJECT_ROOTS.includes(top) ? bases.slice(1) : []
        if (/[<>$*{}]/.test(path) || candidates.length === 0) continue
        if (candidates.some(base => exists(join(base, path))) || ignored(path)) continue
        issues.push(`${docPath}:${start + offset + 2}: command references missing path ${path}`)
      }
    }
  }
  return issues
}

export function markdownFiles(root, directory = 'docs') {
  return readdirSync(join(root, directory), { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap(entry => {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) {
        return entry.name.startsWith('.') || ['node_modules', 'public'].includes(entry.name) ? [] : markdownFiles(root, path)
      }
      return entry.name.endsWith('.md') ? [path] : []
    })
}

export function checkDocs(root, ignored = () => false) {
  const read = path => {
    const full = resolve(root, path)
    return existsSync(full) && statSync(full).isFile() ? readFileSync(full, 'utf8') : null
  }
  const exists = path => existsSync(resolve(root, path))
  return markdownFiles(root).flatMap(docPath => {
    const markdown = read(docPath)
    return [
      ...sourceCitationIssues(markdown, docPath, read),
      ...(docPath === TELEMETRY_DOC ? telemetryRowIssues(markdown, docPath, read) : []),
      ...commandPathIssues(markdown, docPath, exists, ignored),
    ]
  })
}

// Generated build outputs a block creates (for example `--outdir dist`).
function gitIgnored(root) {
  return path => spawnSync('git', ['-C', root, 'check-ignore', '-q', '--no-index', path]).status === 0
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const issues = checkDocs(root, gitIgnored(root))
  if (issues.length) {
    console.error(`Docs source references are stale:\n${issues.map(issue => `  ${issue}`).join('\n')}`)
    process.exitCode = 1
  } else console.log('docs source reference check passed')
}
