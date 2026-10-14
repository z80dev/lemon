import { cp, mkdir, readFile, realpath } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';

const [backend, destination] = process.argv.slice(2);
if (!backend || !destination) throw new Error('Usage: package_image_runtime.ts BACKEND DESTINATION');
const copied = new Set<string>();
interface PackageMetadata { name: string; dependencies?: Record<string, string>; optionalDependencies?: Record<string, string> }
async function copyPackage(name: string, from: string, optional = false): Promise<void> {
  const require = createRequire(join(from, 'package.json'));
  let root: string | undefined;
  let metadata: PackageMetadata | undefined;
  // Native @img packages expose specific addon subpaths, not a "." entry.
  // Resolve their installed package directories without bypassing platform selection.
  for (const modules of require.resolve.paths(name) ?? []) {
    const candidateRoot = join(modules, name);
    try {
      const candidate = JSON.parse(await readFile(join(candidateRoot, 'package.json'), 'utf8')) as PackageMetadata;
      if (candidate.name !== name) throw new Error(`Invalid runtime package ${name}.`);
      root = await realpath(candidateRoot);
      metadata = candidate;
      break;
    } catch (error) {
      if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) throw error;
    }
  }
  if (!root || !metadata) {
    if (optional) return;
    throw new Error(`Missing required runtime package ${name}.`);
  }
  if (copied.has(name)) return;
  copied.add(name);
  const target = join(resolve(destination), 'node_modules', name);
  await mkdir(dirname(target), { recursive: true });
  await cp(root, target, { recursive: true, dereference: true });
  for (const dependency of Object.keys(metadata.dependencies ?? {})) await copyPackage(dependency, root);
  for (const dependency of Object.keys(metadata.optionalDependencies ?? {})) await copyPackage(dependency, root, true);
}
await copyPackage('sharp', resolve(backend));
