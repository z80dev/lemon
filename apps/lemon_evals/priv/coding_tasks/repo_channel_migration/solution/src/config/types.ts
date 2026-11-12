export type Channel = 'email' | 'sms' | 'webhook';
export type Config = { channel: Channel; batchSize: number; sender: string };
export type ConfigInput = Partial<Config>;
