import type { Config } from '../config/types.ts';
export function validateDestination(config: Config, destination: string): void {
  const valid = config.deliveryChannel === 'email' ? destination.includes('@') : config.deliveryChannel === 'sms' ? /^\+[0-9]{8,15}$/.test(destination) : destination.startsWith('https://');
  if (!valid) throw new Error(`invalid ${config.deliveryChannel} destination`);
}
