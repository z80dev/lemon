import type { Message } from '../domain/message.ts';
export function renderSms(item: Message): string {
  if (item.text.length > 160) throw new Error('sms text exceeds 160 characters');
  return item.text;
}
