import { posix } from 'node:path'

// Repository files are useful references in Markdown, but are not site pages.
// Rewrite only relative links escaping docs/; leave page and anchor handling
// to VitePress, including its project-path base and external-link attributes.
export function sourceLink(href, relativePath) {
  if (!relativePath || !href || /^(?:[a-z][a-z\d+.-]*:|\/|#)/i.test(href)) return href
  const [, pathname, suffix] = href.match(/^([^?#]*)(.*)$/)
  const target = posix.normalize(posix.join('docs', posix.dirname(relativePath), pathname))
  if (target === 'docs' || target.startsWith('docs/') || target.startsWith('../')) return href
  return `https://github.com/z80dev/lemon/blob/main/${target}${suffix}`
}

export function repositoryLinks(md) {
  const original = md.renderer.rules.link_open
  md.renderer.rules.link_open = (tokens, index, options, env, self) => {
    const token = tokens[index]
    const href = token.attrGet('href')
    if (href) token.attrSet('href', sourceLink(href, env.relativePath))
    return original ? original(tokens, index, options, env, self) : self.renderToken(tokens, index, options)
  }
}
