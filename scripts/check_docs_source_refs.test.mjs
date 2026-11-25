import assert from 'node:assert/strict'
import test from 'node:test'
import {
  commandPathIssues,
  functionClauses,
  sourceCitationIssues,
  telemetryRowIssues,
} from './check_docs_source_refs.mjs'

const emitter = `defmodule Demo.Emitter do
  @prefix [:demo, :span]

  def emit_ready(meta \\\\ %{}) do
    :telemetry.execute([:demo, :ready], %{count: 1}, meta)
  end

  defp emit_stage(stage, meta) when stage in [:attempt, :failure] do
    LemonCore.Telemetry.emit(
      [:demo, :stage, stage],
      %{count: 1},
      meta
    )
  end

  def span_stop(meta), do: :telemetry.execute(@prefix ++ [:stop], %{}, meta)

  def handle_event([:demo, :ignored], _measurements, _meta, _config), do: :ok

  def unrelated(a, b), do: a + b
  def a, do: 1
  def b, do: 2
  def c, do: 3
  def d, do: 4
  def e, do: 5
  def f, do: 6
end
`

const files = { 'apps/demo/lib/demo/emitter.ex': emitter }
const read = path => files[path] ?? null
const doc = 'docs/telemetry.md'
const link = label => `[\`${label}\`](../apps/demo/lib/demo/emitter.ex)`

function table(...rows) {
  return ['| Event | Metadata | Emitter |', '|---|---|---|', ...rows].join('\n')
}

test('telemetry rows pass only when a linked function emits the event', () => {
  const valid = table(
    `| \`[:demo, :ready]\` | \`meta\` | ${link('Demo.Emitter.emit_ready/1')} |`,
    `| \`[:demo, :stage, :attempt]\` | \`meta\` | ${link('emit_stage/2')} |`,
    `| \`[:demo, :stage, <stage>]\` | \`meta\` | ${link('emit_stage/2')} |`,
    `| \`[:demo, :span, :stop]\` | none | ${link('span_stop/1')} |`,
  )
  assert.deepEqual(telemetryRowIssues(valid, doc, read), [])
})

test('a fixture row naming an event with no emitter fails', () => {
  const phantom = table(
    `| \`[:demo, :ready, :dropped]\` | \`reason\` | ${link('emit_ready/1')} |`,
    `| \`[:demo, :stage, :success]\` | \`meta\` | ${link('emit_stage/2')} |`,
    `| \`[:demo, :ignored]\` | none | ${link('handle_event/4')} |`,
    `| \`[:demo, :ready]\` | \`meta\` | ${link('unrelated/2')} |`,
    '| `[:demo, :ready]` | `meta` | `Demo.Emitter` |',
  )
  assert.deepEqual(telemetryRowIssues(phantom, doc, read), [
    `${doc}:3: no linked function emits [:demo, :ready, :dropped]`,
    `${doc}:4: no linked function emits [:demo, :stage, :success]`,
    `${doc}:5: no linked function emits [:demo, :ignored]`,
    `${doc}:6: no linked function emits [:demo, :ready]`,
    `${doc}:7: [:demo, :ready] names no emitting function link`,
  ])
})

test('tables not headed Event are not catalog rows', () => {
  const consumer = '| Source | Span |\n|---|---|\n| `[:demo, :nothing]` | none |'
  assert.deepEqual(telemetryRowIssues(consumer, doc, read), [])
})

test('function clauses record line ranges and arities with defaults', () => {
  const clauses = functionClauses(emitter)
  assert.deepEqual(clauses.get('emit_ready'), [{ start: 4, end: 6, arity: [0, 1] }])
  assert.deepEqual(clauses.get('emit_stage'), [{ start: 8, end: 14, arity: [2, 2] }])
  assert.deepEqual(clauses.get('handle_event')[0].arity, [4, 4])
})

test('source citations need an existing file, function arity and line', () => {
  const markdown = [
    `${link('emit_ready/0')} ${link('emit_ready/1')} ${link('unrelated/3')} ${link('missing/1')}`,
    '[`emitter.ex:28`](../apps/demo/lib/demo/emitter.ex) [`emitter.ex:29`](../apps/demo/lib/demo/emitter.ex)',
    '[range](../apps/demo/lib/demo/emitter.ex#L1-L99) [`gone.ex:1`](../apps/demo/lib/demo/gone.ex)',
  ].join('\n')
  assert.deepEqual(sourceCitationIssues(markdown, 'docs/page.md', read), [
    'docs/page.md:1: `unrelated/3` is not defined in apps/demo/lib/demo/emitter.ex',
    'docs/page.md:1: `missing/1` is not defined in apps/demo/lib/demo/emitter.ex',
    'docs/page.md:2: apps/demo/lib/demo/emitter.ex has no line 29 (28 lines)',
    'docs/page.md:3: apps/demo/lib/demo/emitter.ex has no line 99 (28 lines)',
    'docs/page.md:3: cited file does not exist: apps/demo/lib/demo/gone.ex',
  ])
})

test('telemetry line citations must sit within five lines of a telemetry call', () => {
  const markdown = '[`emitter.ex:9`](../apps/demo/lib/demo/emitter.ex) [`emitter.ex:2`](../apps/demo/lib/demo/emitter.ex)'
  assert.deepEqual(sourceCitationIssues(markdown, doc, read), [])
  const far = '[`emitter.ex:26`](../apps/demo/lib/demo/emitter.ex)'
  assert.deepEqual(sourceCitationIssues(far, doc, read), [
    `${doc}:1: apps/demo/lib/demo/emitter.ex:26 is not within 5 lines of a telemetry call`,
  ])
})

test('shell blocks must reference existing repository paths', () => {
  const present = new Set(['scripts/test', 'apps/demo/test', 'clients/tui', 'clients/tui/test/ui/a.test.ts'])
  const exists = path => present.has(path)
  const ignored = path => path.startsWith('clients/tui/dist')
  const markdown = [
    '```bash',
    'scripts/test path apps/demo/test apps/demo/test/missing_test.exs # apps/also/ignored',
    'scripts/test path apps/<app>/test "$ROOT/apps/x" --input=/tmp/x.json',
    "lemon learn '@file:docs/user-notes.md' && mix test test/my_app/thing_test.exs",
    '```',
    '```sh',
    'bun --cwd clients/tui test test/ui/a.test.ts test/ui/b.test.ts',
    'tar -C clients/tui/dist/darwin-arm64 tui',
    '```',
    '```elixir',
    'apps/not/a/command.ex',
    '```',
  ].join('\n')
  assert.deepEqual(commandPathIssues(markdown, 'docs/page.md', exists, ignored), [
    'docs/page.md:2: command references missing path apps/demo/test/missing_test.exs',
    'docs/page.md:7: command references missing path test/ui/b.test.ts',
  ])
})
