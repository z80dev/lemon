import lt from 'semver/functions/lt';
import { version } from '../package.json';

// Vite replaces this constant from package.json in development and production.
declare const __APP_VERSION__: string;
export const appVersion = typeof __APP_VERSION__ === 'string' ? __APP_VERSION__ : version;
export const requiresClientUpdate = (current: string, minimum: string) => lt(current, minimum);
