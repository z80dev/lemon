import { readdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import config from '../docs/.vitepress/config.js'

// Contributor/internal references deliberately reached through the docs hub.
export const unlisted = new Map([
  ['README.md', 'Canonical hub, linked from the top navigation.'],
  ['benchmarks/paired-disclosure.md', 'Contributor experiment protocol, not a user benchmark result.'],
  ['contributor/ownership.md', 'Repository ownership policy, linked from the hub.'],
  ['mix-tasks.md', 'Source-development task catalog, linked from the hub.'],
  ['release/deployment_flows.md', 'Maintainer deployment procedures, linked from the hub.'],
  ['release/hex-packages.md', 'Maintainer package publication procedures, linked from the hub.'],
  ['subagent-parent-questions.md', 'Internal design proposal, not a shipped user workflow.'],
  ['testing/deterministic-test-patterns.md', 'Contributor test invariants, linked from the hub.'],
])

export function sidebarPages(items) {
  return items.flatMap(item => [
    ...(item.link?.startsWith('/') ? [item.link === '/' ? 'index.md' : `${item.link.slice(1)}.md`] : []),
    ...sidebarPages(item.items ?? []),
  ])
}

export async function markdownPages(root, prefix = '') {
  const pages = []
  for (const entry of await readdir(new URL(prefix, root), { withFileTypes: true })) {
    if (entry.name.startsWith('.') || ['node_modules', 'public', 'generated'].includes(entry.name)) continue
    const path = `${prefix}${entry.name}`
    if (entry.isDirectory()) pages.push(...await markdownPages(root, `${path}/`))
    else if (entry.name.endsWith('.md')) pages.push(path)
  }
  return pages.sort()
}

export function orphanPages(pages, sidebar, allowlist = unlisted) {
  const listed = new Set(sidebarPages(sidebar))
  return pages.filter(page => !listed.has(page) && !allowlist.has(page)).sort()
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const pages = await markdownPages(new URL('../docs/', import.meta.url))
  const orphans = orphanPages(pages, config.themeConfig.sidebar)
  if (orphans.length) {
    console.error(`Docs pages missing from sidebar or documented allowlist:\n${orphans.map(page => `  ${page}`).join('\n')}`)
    process.exitCode = 1
  } else console.log('docs navigation check passed')
}
