import metadata from '../../package.json';

declare const LEMON_BOT_VERSION: string;
export const productVersion = typeof LEMON_BOT_VERSION === 'undefined' ? metadata.version : LEMON_BOT_VERSION;
