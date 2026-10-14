import { cp, mkdir, readFile, realpath } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';

const [backend, destination, platform] = process.argv.slice(2);
if (!backend || !destination || !platform) throw new Error('Usage: package_image_runtime.ts BACKEND DESTINATION PLATFORM');
const addonPlatform = platform === 'linux-x86_64' ? 'linux-x64' : platform;
if (!['linux-x64', 'linux-arm64', 'darwin-arm64'].includes(addonPlatform)) throw new Error('Unsupported native image platform.');
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
// Sharp JS and its transitive JS dependencies are compiled into the executable.
// Only the real host-native addon and sibling shared library packages stay on disk.
await copyPackage(`@img/sharp-${addonPlatform}`, resolve(backend));
await copyPackage(`@img/sharp-libvips-${addonPlatform}`, resolve(backend));
