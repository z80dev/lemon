import { X } from 'lucide-react';
import type { TranscriptEntry } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { plainLine } from '../../live';
import { useQuery } from '../../ui';

export function replyPreview(entry: TranscriptEntry) {
  const text = entry.kind === 'message' ? plainLine(entry.text) : entry.kind === 'card' && entry.card.type === 'text' ? plainLine(entry.card.text) : '';
  const characters = Array.from(text || (entry.kind === 'user_attachment' || entry.kind === 'message' && entry.attachmentIds.length ? 'File attachment' : 'Message'));
  return `${entry.actor.displayName}: ${characters.slice(0, 40).join('')}${characters.length > 40 ? '…' : ''}`;
}

export function ComposerReply({ id, cancel }: { id: string; cancel: () => void }) {
  const { client } = useApp();
  const query = useQuery(`composer-reply:${id}`, () => client.call('GET /entries/:id', { params: { id } }));
  // Query state is replaced after a key change; never flash a previous reply's author.
  const entry = query.data?.id === id ? query.data : undefined;
  return <div className="chat-reply-chip"><span>{entry ? `Replying to ${replyPreview(entry)}` : query.error ? 'Replying to an unavailable message' : 'Loading reply…'}</span><button type="button" className="icon-button" aria-label="Cancel reply" onClick={cancel}><X size={14}/></button></div>;
}
