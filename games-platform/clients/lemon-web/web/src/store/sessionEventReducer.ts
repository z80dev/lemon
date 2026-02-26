import type { Message, SessionEvent } from '@lemon-web/shared';
import type { LemonState, MessageWithMeta } from './useLemonStore';
import { createNotification } from './notificationHelpers';

type SessionEventState = Pick<
  LemonState,
  'messagesBySession' | 'toolExecutionsBySession' | 'statsBySession' | '_insertionCounters' | 'notifications'
>;

type SessionEventReduction = Pick<
  LemonState,
  'messagesBySession' | 'toolExecutionsBySession' | 'statsBySession' | '_insertionCounters'
> & {
  notifications?: LemonState['notifications'];
};

export function reduceSessionEvent(
  state: SessionEventState,
  sessionId: string,
  event: SessionEvent,
  eventSeq?: number,
  now: number = Date.now()
): SessionEventReduction {
  const messagesBySession = { ...state.messagesBySession };
  const toolExecutionsBySession = { ...state.toolExecutionsBySession };
  const statsBySession = { ...state.statsBySession };
  const insertionCounters = { ...state._insertionCounters };
  const messages: MessageWithMeta[] = [...(messagesBySession[sessionId] ?? [])];

  const getNextInsertionIndex = (): number => {
    const current = insertionCounters[sessionId] ?? 0;
    insertionCounters[sessionId] = current + 1;
    return current;
  };

  switch (event.type) {
    case 'agent_end': {
      const newMessages = (event.data?.[0] as Message[]) ?? [];
      const merged = [...messages];
      for (const nextMessage of newMessages) {
        upsertSessionMessage(merged, {
          ...nextMessage,
          _event_seq: eventSeq,
          _insertionIndex: getNextInsertionIndex(),
        });
      }
      messagesBySession[sessionId] = sortSessionMessages(merged);
      break;
    }
    case 'message_start':
    case 'message_update':
    case 'message_end':
    case 'turn_end': {
      const nextMessage = (event.data?.[0] as Message | undefined) ?? null;
      if (nextMessage) {
        upsertSessionMessage(messages, {
          ...nextMessage,
          _event_seq: eventSeq,
          _insertionIndex: getNextInsertionIndex(),
        });
        messagesBySession[sessionId] = sortSessionMessages(messages);
      }
      break;
    }
    case 'tool_execution_start': {
      const [id, name, args] = (event.data ?? []) as [string, string, Record<string, unknown>];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      map[id] = {
        id,
        name,
        args,
        status: 'running',
        startedAt: Date.now(),
        updatedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'tool_execution_update': {
      const [id, name, args, partial] = (event.data ?? []) as [
        string,
        string,
        Record<string, unknown>,
        unknown,
      ];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      const existing = map[id];
      map[id] = {
        id,
        name,
        args,
        status: existing?.status ?? 'running',
        partial,
        result: existing?.result,
        startedAt: existing?.startedAt ?? Date.now(),
        updatedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'tool_execution_end': {
      const [id, name, result, isError] = (event.data ?? []) as [string, string, unknown, boolean];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      const existing = map[id];
      map[id] = {
        id,
        name,
        args: existing?.args ?? null,
        status: isError ? 'error' : 'complete',
        partial: existing?.partial,
        result,
        startedAt: existing?.startedAt ?? Date.now(),
        updatedAt: Date.now(),
        endedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'error': {
      const reason = String((event.data?.[0] as string | undefined) ?? 'unknown error');
      return {
        messagesBySession,
        toolExecutionsBySession,
        statsBySession,
        _insertionCounters: insertionCounters,
        notifications: [
          ...state.notifications,
          createNotification({
            idPrefix: 'session-error',
            message: `Session ${sessionId}: ${reason}`,
            level: 'error',
            now,
          }),
        ],
      };
    }
    default:
      break;
  }

  return {
    messagesBySession,
    toolExecutionsBySession,
    statsBySession,
    _insertionCounters: insertionCounters,
  };
}

function upsertSessionMessage(messages: MessageWithMeta[], message: MessageWithMeta): void {
  const key = getMessageIdentityKey(message);
  const existingIndex = messages.findIndex((existing) => getMessageIdentityKey(existing) === key);

  if (existingIndex >= 0) {
    const existing = messages[existingIndex];
    messages[existingIndex] = {
      ...message,
      _insertionIndex: existing._insertionIndex,
      _event_seq: existing._event_seq ?? message._event_seq,
    };
    return;
  }

  messages.push(message);
}

function getMessageIdentityKey(message: MessageWithMeta): string {
  const seqPart = message._event_seq !== undefined ? `seq:${message._event_seq}:` : '';

  if (message.role === 'tool_result') {
    return `${seqPart}tool:${message.tool_call_id}`;
  }

  return `${seqPart}${message.role}:${message.timestamp}`;
}

function sortSessionMessages(messages: MessageWithMeta[]): MessageWithMeta[] {
  return [...messages].sort((left, right) => {
    if (left._event_seq !== undefined && right._event_seq !== undefined) {
      if (left._event_seq !== right._event_seq) {
        return left._event_seq - right._event_seq;
      }
    }

    if (left._event_seq !== undefined && right._event_seq === undefined) {
      return 1;
    }
    if (left._event_seq === undefined && right._event_seq !== undefined) {
      return -1;
    }

    if (left.timestamp !== right.timestamp) {
      return left.timestamp - right.timestamp;
    }

    return left._insertionIndex - right._insertionIndex;
  });
}

export function getMessageReactKey(message: MessageWithMeta): string {
  const seqPart = message._event_seq !== undefined ? `${message._event_seq}-` : '';
  const indexPart = `-${message._insertionIndex}`;

  if (message.role === 'tool_result') {
    return `${seqPart}tool-${message.tool_call_id}${indexPart}`;
  }

  return `${seqPart}${message.role}-${message.timestamp}${indexPart}`;
}
