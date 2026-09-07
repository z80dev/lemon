import test from 'node:test'
import assert from 'node:assert/strict'
import { sourceLink } from './source-links.mjs'

test('repository references retain source extension and fragment', () => {
  assert.equal(sourceLink('../apps/lemon_router/lib/lemon_router/run_process.ex#L46', 'why-beam-for-agents.md'),
    'https://github.com/z80dev/lemon/blob/main/apps/lemon_router/lib/lemon_router/run_process.ex#L46')
  assert.equal(sourceLink('../../clients/lemon-browser-node/README.md', 'tools/web.md'),
    'https://github.com/z80dev/lemon/blob/main/clients/lemon-browser-node/README.md')
})
test('docs, external links, anchors and paths outside the repo are preserved', () => {
  for (const href of ['../install.md#setup', '/getting-started/quickstart', '#setup', 'https://example.com', 'mailto:a@example.com', '../../../outside']) {
    assert.equal(sourceLink(href, 'tools/web.md'), href)
  }
})
