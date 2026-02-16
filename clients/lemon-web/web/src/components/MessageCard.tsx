import type { Message } from '@lemon-web/shared';
import { useMemo } from 'react';
import { ContentBlockRenderer } from './ContentBlockRenderer';
import { useLemonStore } from '../store/useLemonStore';

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
  const toolTrust =
    message.role === 'tool_result'
      ? resolveToolResultTrust(message)
      : null;
  const toolStatus =
    message.role === 'tool_result'
      ? message.is_error
        ? 'Error'
        : toolTrust === 'untrusted'
          ? 'Untrusted'
          : 'Success'
      : null;

  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const toolExecution = useLemonStore((state) => {
    if (message.role !== 'tool_result') return null;
    if (!activeSessionId) return null;
    return state.toolExecutionsBySession[activeSessionId]?.[message.tool_call_id] ?? null;
  });

  const toolDuration = useMemo(() => {
    if (!toolExecution?.startedAt) return null;
    const effectiveEnd = toolExecution.endedAt ?? toolExecution.updatedAt ?? toolExecution.startedAt;
    const durationMs = Math.max(0, effectiveEnd - toolExecution.startedAt);
    if (durationMs < 1000) return `${durationMs}ms`;
    const seconds = Math.round(durationMs / 100) / 10;
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const remainder = Math.round((seconds % 60) * 10) / 10;
    return `${minutes}m ${remainder}s`;
  }, [toolExecution]);

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
          <div>{toolStatus}</div>
          <div className="message-card__meta">
            {toolDuration ? <span>duration: {toolDuration}</span> : null}
            {message.details ? <span>details: {Object.keys(message.details).length}</span> : null}
          </div>
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

function resolveToolResultTrust(message: Extract<Message, { role: 'tool_result' }>): 'trusted' | 'untrusted' {
  if (message.trust) return message.trust;
  if (message.trust_metadata?.untrusted === true) return 'untrusted';
  if (message.trust_metadata?.trusted === false) return 'untrusted';
  return 'trusted';
}
