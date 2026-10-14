import type { Attachment, Snapshot, TranscriptEntry } from '../src/index.ts';

export const snapshot: Snapshot = {
  cursor: '9007199254740993',
  user: {
    id: 'user_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, email: 'owner@example.org', displayName: 'Owner', avatarAttachmentId: null,
    preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false,
      voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false },
    notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true },
  },
  workspace: { id: 'workspace_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, name: 'Workspace', ownerUserId: 'user_1', enabled: true, timezone: 'UTC' },
  member: { id: 'member_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, userId: 'user_1', displayName: 'Owner', email: 'owner@example.org', role: 'owner', enabled: true },
  capabilities: { controlConnected: true, methods: [], stt: true, tts: true, imageGeneration: false, apns: false, webPush: false,
    vapidPublicKey: null, attachmentMaxBytes: 26214400, videoMaxBytes: 209715200, maxAttachments: 6, minClientVersions: { web: '1', macos: '1', ios: '1' } },
  bots: [], machines: [], conversations: [], sections: [], notifications: [], activeRuns: [],
  hasMore: { bots: false, machines: false, conversations: false, notifications: false },
};

export const attachment: Attachment = {
  id: 'attachment_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, ownerUserId: 'user_1', conversationId: 'conversation_1', botId: null,
  filename: 'sample.webm', mime: 'audio/webm', size: 4, sha256: 'server-computed', width: null, height: null, durationMs: 1000,
  source: 'upload', state: 'ready', preview: 'audio',
  provenance: { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null },
};

export type MessageEntry = Extract<TranscriptEntry, { kind: 'message' }>;
export const entry: MessageEntry = {
  id: 'entry_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, conversationId: 'conversation_1', seq: 1, timestampMs: 1,
  actor: { kind: 'bot', id: 'bot_1', displayName: 'Bot' }, clientNonce: null, batchId: null, replyToEntryId: null,
  runId: 'run_1', targetedUserId: null, reactions: [], kind: 'message', role: 'assistant', text: 'Hi', streaming: true, attachmentIds: [],
};

export interface FetchBoundary { clientFetch: typeof fetch; requests: Request[] }
export function fetchBoundary(handler: (request: Request) => Response | Promise<Response>): FetchBoundary {
  const requests: Request[] = [];
  const clientFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    requests.push(request.clone());
    return handler(request);
  }) as typeof fetch;
  return { clientFetch, requests };
}
