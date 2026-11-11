import type { Config } from './types.ts';
export const defaults: Readonly<Config> = Object.freeze({ channel: 'email', batchSize: 25, sender: 'harbor' });
