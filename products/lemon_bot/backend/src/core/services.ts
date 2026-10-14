import type { Database } from 'bun:sqlite';
import type * as P from '../../../contracts/protocol';
import type { InvocationMcpServer } from '../runtime/runs';

export interface HttpClient { (input: RequestInfo | URL, init?: RequestInit): Promise<Response> }
export type Entity = P.Resource & Record<string, unknown>;
export interface Principal { kind: 'user' | 'bot' | 'hook' | 'integration'; id: string; userId: string; workspaceId: string; role: P.Role; sessionId: string | null; botId: string | null; deviceId: string | null; scopes?: string[] }
export type Authentication = 'public' | 'member' | 'admin' | 'owner' | 'bot' | 'hook' | 'integration' | 'optional';
export interface Route { method: string; path: string; auth: Authentication; mutation?: boolean; body?: 'json' | 'multipart' | 'none'; status?: number; authorizeReplay?(context: RequestContext): Promise<void> | void; handler(context: RequestContext): Promise<unknown> | unknown }
export interface InternalInvocationOptions { botLifecycle?: { botId: string; userId: string; action: string } }
export interface RequestContext { request: Request; params: Record<string, string>; query: URLSearchParams; body: unknown; user: Principal | null; services: BackendServices; requestId: string; route: Route; nonceResourceIds: string[]; internalBotLifecycle?: InternalInvocationOptions['botLifecycle'] }
export interface EntityStore {
  db: Database;
  get<T = Entity>(collection: string, id: string): T | null;
  require<T = Entity>(collection: string, id: string): T;
  list<T = Entity>(collection: string, predicate?: (value: T) => boolean): T[];
  put<T>(collection: string, value: T & { id: string }): T;
  remove(collection: string, id: string): void;
  transaction<T>(operation: () => T): T;
  metadata<T>(key: string): T | null;
  setMetadata(key: string, value: unknown): void;
}
export interface EventAudience { userIds?: string[]; conversationId?: string; botId?: string; machineId?: string; admin?: boolean; public?: boolean }
export interface EventService {
  emit<K extends keyof P.ResourceEventPayloads>(event: K, payload: P.ResourceEventPayloads[K], audience?: EventAudience): P.RealtimeEvent;
  cursor(): string;
  earliestCursor(): string;
  replay(principal: Principal, cursor: string, conversationIds?: string[]): P.RealtimeEvent[];
  visible(principal: Principal, event: P.RealtimeEvent, audience: EventAudience): boolean;
  subscribe(listener: (event: P.RealtimeEvent, audience: EventAudience) => void): () => void;
}
export interface AccessService {
  authenticate(request: Request, policy?: Authentication): Promise<Principal | null>;
  user(userId: string): P.User;
  member(userId: string): P.Member;
  requireRole(principal: Principal, role: 'admin' | 'owner'): void;
  bot(principal: Principal, botId: string, manage?: boolean): P.Bot;
  conversation(principal: Principal, conversationId: string): P.Conversation;
  machine(principal: Principal, machineId: string, manage?: boolean): P.Machine;
  attachment(principal: Principal, attachmentId: string): P.Attachment;
  canRead(principal: Principal, collection: string, entity: unknown): boolean;
  revokeUser(userId: string): Promise<void>;
  session(userId: string, deviceId?: string | null): Promise<P.AuthResult>;
  issueReauth(userId: string): { reauthToken: string; expiresAtMs: number };
  consumeReauth(userId: string, token: string): void;
}
export interface MutationService {
  execute<T>(context: RequestContext, operation: () => Promise<T> | T): Promise<T>;
  checkRevision(resource: { revision: number }, revision: unknown): void;
  preview(principal: Principal, target: { id: string; revision: number }, action: string, name: string, effects: string[], affected?: P.ScopeEffect[], binding?: unknown, expiresInMs?: number): P.Confirmation;
  confirm(principal: Principal, target: { id: string; revision: number }, action: string, body: unknown, binding?: unknown): void;
  digest(value: unknown): string;
}
export interface LemonService {
  connected: boolean;
  methods: string[];
  call<T = unknown>(method: string, params?: Record<string, unknown>, options?: { mutation?: boolean; timeoutMs?: number; resourceIds?: string[] }): Promise<T>;
  onEvent(listener: (event: string, payload: unknown) => void): () => void;
  onConnected(listener: () => void): () => void;
  start(): void;
  close(): void;
}
export interface RuntimeService {
  submit(principal: Principal, conversation: P.Conversation, bot: P.Bot, message: P.MessageSend, context?: RequestContext): Promise<{ run: P.Run; delivery: P.MessageReceipt['delivery'][number] }>;
  send(principal: Principal, conversationId: string, message: P.MessageSend, context?: RequestContext): Promise<P.MessageReceipt>;
  cancel(principal: Principal, runId: string, reason?: string): Promise<P.Run>;
  revokeConnectorInvocations(actor: Principal, botId: string, connectorId: string): Promise<{ runIds: string[]; status: 'cancelled' | 'outcome_unknown' }>;
  reconcile(): Promise<void>;
  sessionKey(conversation: P.Conversation, bot: P.Bot): string;
}
export interface AttachmentService {
  create(principal: Principal, bytes: Uint8Array, metadata: P.AttachmentUpload & { filename: string; mime?: string; source?: P.Attachment['source']; provenance?: P.Attachment['provenance'] }): Promise<P.Attachment>;
  copy(principal: Principal, sourceAttachmentId: string, metadata: P.AttachmentUpload): Promise<P.Attachment>;
  bytes(attachmentId: string): Promise<Uint8Array<ArrayBuffer>>;
  download(principal: Principal, attachmentId: string): P.Download;
}
export interface GateService {
  create<T = unknown>(principal: Principal, kind: 'approval' | 'question' | 'human_step' | 'secret_request' | 'consent', input: unknown): Promise<T>;
  resolve<T = unknown>(principal: Principal, collection: string, id: string, body: unknown): Promise<T>;
  wait<T = unknown>(collection: string, id: string): Promise<T>;
  cancelUser(userId: string): void;
}
export interface IntegrationServices {
  admission(principal: Principal, botId: string, routineId?: string): Promise<void>;
  effectivePolicy(principal: Principal, botId?: string): Promise<P.EffectivePolicy>;
  connectorConfig(principal: Principal, botId: string, conversationId?: string, operationId?: string): Promise<InvocationMcpServer[]>;
  connectorTemplates?(botId: string): Promise<InvocationMcpServer[]>;
  sendApprovedDraft(principal: Principal, draft: P.Draft): Promise<{ providerMessageId: string | null; runId: string | null }>;
  emitProviderNotifications(notification: P.Notification): Promise<void>;
  channelIngress(input: { principal: Principal; botId: string; channelBindingId: string; externalThreadId: string; text: string; attachmentIds?: string[]; clientNonce: string }): Promise<P.MessageReceipt>;
  providerCapabilities(): Partial<P.Capabilities> & { inventory?: unknown[] };
  speech?(principal: Principal, request: P.SpeechRequest, provenance?: P.DeliverableProvenance): Promise<P.SpeechResult>;
  deprovisionUser?(userId: string): Promise<void>;
  requireSSO?(userId: string): Promise<boolean> | boolean;
  reconcile?(): Promise<void>;
  defaultBotIds?(principal: Principal): Promise<string[]>;
  authorizeConnector?(principal: Principal, input: { connectorId: string; botId: string; conversationId: string; toolName: string; operationId: string }): Promise<void>;
  connectorProvisioning?(principal: Principal, botId: string): Promise<unknown>;
  authorizeExportAttachment?(principal: Principal, attachmentId: string): void;
  assertChannelHandoff?(principal: Principal, source: P.Conversation, target: P.Bot, returnConversationId: string): void;
  returnChannelHandoff?(principal: Principal, conversationId: string, text: string, sourceRunId?: string): Promise<void>;
  requestConnectorConsent?(principal: Principal, input: { connectorId: string; botId: string; conversationId: string; operationId: string }): Promise<P.ConnectorConsent>;
  deleteBotConnectors?(principal: Principal, botId: string, confirmedBotRevision: number, connectorIds?: string[]): Promise<void>;
  previewDeprovisionUser?(userId: string): { affected: P.ScopeEffect[]; binding: P.JSONObject };
  endProviderSessions?(userId: string): Promise<void>;
  captureUsage?(principal: Principal, report: P.UsageReport, atMs?: number): void;
  captureAction?(principal: Principal, metadata: P.JSONObject, sourceId?: string): void;
  dispose?(): void | Promise<void>;
  refreshPolicy?(principal: Principal, botIds?: string[], options?: { workspace?: boolean }): Promise<void>;
  canReadResource?(principal: Principal, collection: string, entity: unknown): boolean;
  sharedProfilePolicy?(botId: string): Promise<P.EffectivePolicy>;
  observeAccountTeardown?(operationId: string): Promise<P.ProviderCleanupResult[]>;
}
export interface BackendConfiguration {
  publicUrl: string; controlUrl: string; operatorToken: string; dataDir: string; host: string; port: number;
  trustedOverlay: boolean; operator: P.OperatorConfiguration;
}
export interface BackendServices {
  config: BackendConfiguration; store: EntityStore; events: EventService; auth: AccessService; mutations: MutationService;
  lemon: LemonService; runtime: RuntimeService; attachments: AttachmentService; gates: GateService; integrations: IntegrationServices;
  http?: HttpClient;
  id(prefix?: string): string;
  now(): number;
  resource<T extends object>(prefix: string, fields: T): T & P.Resource;
  update<T extends { revision: number; updatedAtMs: number }>(resource: T, changes: Partial<T>): T;
  page<T>(context: RequestContext, values: T[], options?: { ascending?: boolean; key?: (value: T) => string; binding?: unknown }): P.Page<T>;
  pageAfter(context: RequestContext, options?: { ascending?: boolean; binding?: unknown }): string | null;
  secret(ref: string): Promise<string>;
  encrypt(value: unknown): string;
  decrypt<T = unknown>(value: string): T;
  audit(principal: Principal | null, action: string, targetId: string, outcome: P.AuditRecord['outcome'], details?: P.JSONObject, requestId?: string): P.AuditRecord;
  entry(principal: Principal, conversationId: string, payload: Record<string, unknown>): P.TranscriptEntry;
  notify(principal: Principal, input: Record<string, unknown>): P.Notification;
  invoke<T = unknown>(principal: Principal, method: string, path: string, body?: unknown, options?: InternalInvocationOptions): Promise<T>;
  syncBotProfile(principal: Principal, botId: string): Promise<void>;
}
