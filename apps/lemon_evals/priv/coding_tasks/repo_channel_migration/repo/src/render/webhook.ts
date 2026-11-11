import type { Message } from '../domain/message.ts';
export function renderWebhook(item: Message): string { return JSON.stringify({ id: item.id, text: item.text }); }
