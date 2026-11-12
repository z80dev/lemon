import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { routes } from '../src/http/manifest.ts';
export function checkContracts(root: string): string[] {
  const issues: string[] = [];
  function visit(directory: string): void {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) { visit(path); continue; }
      if (!entry.name.endsWith('.ts')) continue;
      const source = readFileSync(path, 'utf8');
      if (/\bconsole\s*\./.test(source)) issues.push(`${path}: source uses console; record audit events instead`);
      if (/\bDate\s*\.\s*now\s*\(/.test(source)) issues.push(`${path}: source uses wall clock; inject context.clock`);
      for (const match of source.matchAll(/(?:from\s*|import\s*)['"](\.[^'"]+)['"]/g)) {
        if (!match[1].endsWith('.ts')) issues.push(`${path}: relative imports must use .ts extensions`);
      }
    }
  }
  visit(join(root, 'src'));
  const names = new Set<string>(); const paths = new Set<string>();
  for (const route of routes) {
    if (!Object.isFrozen(route)) issues.push(`${route.name}: route descriptor must be frozen`);
    if (!/^[a-z]+(?:-[a-z]+)*$/.test(route.name)) issues.push(`${route.name}: route name must be lower-kebab-case`);
    if (names.has(route.name)) issues.push(`${route.name}: duplicate route name`);
    names.add(route.name);
    const key = `${route.method} ${route.path}`;
    if (paths.has(key)) issues.push(`${key}: duplicate method/path`);
    paths.add(key);
    if (!route.path.startsWith('/v1/')) issues.push(`${key}: route path must start /v1/`);
    if (route.method === 'POST' && !route.requiresActor) issues.push(`${route.name}: mutations require an actor`);
  }
  return issues;
}
