import sharpModule from 'sharp';

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
// The release compiler bundles Sharp's complete JS dependency graph and
// replaces only its addon loader with an absolute on-disk native path.
export default sharpModule;
