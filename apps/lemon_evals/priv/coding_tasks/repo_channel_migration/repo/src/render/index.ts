import type { Config } from '../config/types.ts';
import type { Message } from '../domain/message.ts';
import { renderEmail } from './email.ts';
import { renderSms } from './sms.ts';
import { renderWebhook } from './webhook.ts';
export function render(config: Config, item: Message): string {
  switch (config.deliveryChannel) { case 'email': return renderEmail(item); case 'sms': return renderSms(item); case 'webhook': return renderWebhook(item); }
}
