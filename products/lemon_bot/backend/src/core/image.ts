import { createRequire } from 'node:module';
import type sharpModule from 'sharp';
import { executablePath, packagedRuntime } from './layout';

// sharp dynamically loads its host-specific addon and libvips. Keep those real
// runtime dependencies beside the compiled executable, not in the user's cwd.
const requireImage = createRequire(packagedRuntime ? executablePath : import.meta.url);
const sharp: typeof sharpModule = requireImage('sharp');
export default sharp;
