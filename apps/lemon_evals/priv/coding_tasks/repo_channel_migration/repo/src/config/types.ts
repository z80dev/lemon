export type Channel = 'email' | 'sms' | 'webhook';
export type Config = { deliveryChannel: Channel; batchSize: number; sender: string };
export type ConfigInput = Partial<Config>;
