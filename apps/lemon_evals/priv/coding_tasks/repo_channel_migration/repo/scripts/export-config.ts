import { fromEnvironment } from '../src/config/environment.ts';
import { serializeConfig } from '../src/config/storage.ts';
process.stdout.write(serializeConfig(fromEnvironment(process.env)));
