import type { Message } from '../domain/message.ts';
export function renderEmail(item: Message): string { return `Subject: Harbor update\n\n${item.text}`; }
