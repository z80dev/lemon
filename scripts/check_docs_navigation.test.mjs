import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import test from 'node:test'
import { markdownPages, orphanPages } from './check_docs_navigation.mjs'

test('nested sidebar, home and explicit allowlist cover only their own pages', () => {
  assert.deepEqual(orphanPages(['index.md', 'tools/shell.md', 'internal.md', 'new.md', 'other.md'], [
    { link: '/' }, { items: [{ link: '/tools/shell' }] },
  ], new Map([['internal.md', 'Design note']])), ['new.md', 'other.md'])
})

test('recursive scan excludes assets, dependencies and generated directories', async () => {
  const root = await mkdtemp(join(tmpdir(), 'lemon-nav-test-'))
  try {
    for (const dir of ['nested', '.vitepress', 'public', 'node_modules', 'generated']) {
      await mkdir(join(root, dir))
      await writeFile(join(root, dir, 'page.md'), '# Page')
    }
    await writeFile(join(root, 'index.md'), '# Home')
    await writeFile(join(root, 'image.svg'), '<svg/>')
    assert.deepEqual(await markdownPages(pathToFileURL(`${root}/`)), ['index.md', 'nested/page.md'])
  } finally { await rm(root, { recursive: true, force: true }) }
})
