import type { Config } from './types.ts';
export const defaults: Readonly<Config> = Object.freeze({ deliveryChannel: 'email', batchSize: 25, sender: 'harbor' });
