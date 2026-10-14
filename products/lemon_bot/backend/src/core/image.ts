import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import type sharpModule from 'sharp';
import type { Sharp, SharpOptions } from 'sharp';
import { executablePath, packagedRuntime } from './layout';

// Bun's compiled module resolver does not search sibling node_modules for a
// bare external package name. Load the real on-disk entrypoint explicitly;
// sharp's own native-addon imports then resolve from its installed directory.
const requireImage = createRequire(packagedRuntime ? executablePath : import.meta.url);
let imageModule: typeof sharpModule | undefined;
export function reportImageFailure(error: unknown, phase: 'load' | 'decode'): void {
  const message = error instanceof Error ? error.message : '';
  let classification = phase === 'load' ? 'image-runtime-load-failed' : 'image-decode-failed';
  if (/Library not loaded|cannot open shared object|Incompatible library version/i.test(message)) classification = 'native-shared-library-unavailable';
  else if (/symbol not found|undefined symbol|CXXABI_/i.test(message)) classification = 'native-symbol-unavailable';
  else if (/Could not load the "sharp" module/i.test(message)) classification = 'sharp-native-addon-unavailable';
  else if (/Cannot find|Cannot resolve|MODULE_NOT_FOUND/i.test(message)) classification = 'runtime-dependency-unresolved';
  else if (/Input buffer|invalid|corrupt|damaged|pngload/i.test(message)) classification = 'image-data-rejected';
  const dependency = message.match(/(?:Cannot find|Cannot resolve) (?:package|module) ['"]((?:@img\/)?[a-z0-9-]+)(?:\/[^'"]*)?['"]/i)?.[1];
  const allowedDependency = dependency && /^(?:sharp|detect-libc|semver|@img\/(?:colour|sharp-(?:libvips-)?(?:darwin|linux|linuxmusl)-(?:arm64|x64)))$/.test(dependency) ? dependency : null;
  // Emit only classifications and allowlisted package identifiers. Never raw
  // errors: their paths, user file names and buffer content may be private.
  process.stderr.write(`LEMON_BOT_IMAGE_DIAGNOSTIC ${JSON.stringify({ phase, classification, dependency: allowedDependency })}\n`);
}
export default function sharp(bytes: Uint8Array, options: SharpOptions): Sharp {
  let loaded: typeof sharpModule;
  try {
    loaded = imageModule ??= requireImage(packagedRuntime
      ? resolve(dirname(executablePath), '../node_modules/sharp/lib/index.js')
      : 'sharp');
  } catch (error) {
    reportImageFailure(error, 'load');
    throw error;
  }
  // Native image libraries are needed only for actual image decoding, never
  // for version/help or a backend with no image request.
  return loaded(bytes, options);
}
