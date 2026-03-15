/**
 * Message selector hooks.
 */

import { useAppSelector } from './useAppState.js';
import type { NormalizedMessage, NormalizedAssistantMessage } from '../../state.js';

export function useMessages(): NormalizedMessage[] {
  return useAppSelector((s) => s.messages);
}

export function useStreamingMessage(): NormalizedAssistantMessage | null {
  return useAppSelector((s) => s.streamingMessage);
}
