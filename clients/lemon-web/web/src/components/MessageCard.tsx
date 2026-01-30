import type { Message } from '@lemon-web/shared';
import { ContentBlockRenderer } from './ContentBlockRenderer';

interface MessageCardProps {
  message: Message;
}

export function MessageCard({ message }: MessageCardProps) {
  const roleClass = `message-card message-card--${message.role}`;
  const timestamp = new Date(message.timestamp).toLocaleTimeString();
  const toolMeta =
    message.role === 'tool_result'
      ? `tool ${message.tool_name} (${message.tool_call_id})`
      : null;

  return (
    <article className={roleClass}>
      <header className="message-card__header">
        <span className="message-card__role">
          {message.role}
          {toolMeta ? ` · ${toolMeta}` : ''}
        </span>
        <span className="message-card__time">{timestamp}</span>
      </header>
      <div className="message-card__content">
        <ContentBlockRenderer message={message} />
      </div>
      {message.role === 'tool_result' ? (
        <footer className="message-card__footer">
          <div>{message.is_error ? 'Error' : 'Success'}</div>
          {message.details ? <div>details: {Object.keys(message.details).length}</div> : null}
        </footer>
      ) : null}
      {'usage' in message && message.usage ? (
        <footer className="message-card__footer">
          <div>
            tokens: {message.usage.total_tokens ?? '-'} | input:{' '}
            {message.usage.input ?? '-'} | output: {message.usage.output ?? '-'}
          </div>
          <div>stop: {message.stop_reason ?? 'n/a'}</div>
        </footer>
      ) : null}
    </article>
  );
}
