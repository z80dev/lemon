import type { Config } from '../config/types.ts';
export function retryPolicy(config: Config): { attempts: number; delayMs: number } {
  return config.deliveryChannel === 'webhook' ? { attempts: 5, delayMs: 1000 } : config.deliveryChannel === 'sms' ? { attempts: 2, delayMs: 5000 } : { attempts: 3, delayMs: 2000 };
}
