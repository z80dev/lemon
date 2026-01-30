/**
 * Protocol types for communication with the Lemon debug agent RPC.
 *
 * Based on the wire format defined in LEMON_TUI_PLAN.md section 2.4
 */

// ============================================================================
// Wire Message Envelopes
// ============================================================================

/** Ready message sent when server is initialized */
export interface ReadyMessage {
  type: 'ready';
  cwd: string;
  model: {
    provider: string;
    id: string;
  };
  debug: boolean;
  ui: boolean;
}

/** Event wrapper for session events */
export interface EventMessage {
  type: 'event';
  event: SessionEvent;
}

/** Stats response */
export interface StatsMessage {
  type: 'stats';
  stats: SessionStats;
}

/** Pong response to ping */
export interface PongMessage {
  type: 'pong';
}

/** Debug info message */
export interface DebugMessage {
  type: 'debug';
  message: string;
  argv?: string[];
}

/** Error message */
export interface ErrorMessage {
  type: 'error';
  message: string;
}

/** Save result message */
export interface SaveResultMessage {
  type: 'save_result';
  ok: boolean;
  path?: string;
  error?: string;
}

/** Sessions list response */
export interface SessionsListMessage {
  type: 'sessions_list';
  sessions: SessionSummary[];
  error?: string;
}

/** UI request from server - requires overlay response */
export interface UIRequestMessage {
  type: 'ui_request';
  id: string;
  method: 'select' | 'confirm' | 'input' | 'editor';
  params: UIRequestParams;
}

/** UI signal (notification) from server - no response needed */
export interface UISignalMessage {
  type: 'ui_notify' | 'ui_status' | 'ui_widget' | 'ui_working' | 'ui_set_title' | 'ui_set_editor_text';
  params: Record<string, unknown>;
}

export type ServerMessage =
  | ReadyMessage
  | EventMessage
  | StatsMessage
  | PongMessage
  | DebugMessage
  | ErrorMessage
  | SaveResultMessage
  | SessionsListMessage
  | UIRequestMessage
  | UISignalMessage;

// ============================================================================
// Client Commands
// ============================================================================

export interface PromptCommand {
  type: 'prompt';
  text: string;
}

export interface StatsCommand {
  type: 'stats';
}

export interface PingCommand {
  type: 'ping';
}

export interface DebugCommand {
  type: 'debug';
}

export interface AbortCommand {
  type: 'abort';
}

export interface ResetCommand {
  type: 'reset';
}

export interface SaveCommand {
  type: 'save';
}

export interface ListSessionsCommand {
  type: 'list_sessions';
}

export interface QuitCommand {
  type: 'quit';
}

export interface UIResponseCommand {
  type: 'ui_response';
  id: string;
  result: unknown;
  error: string | null;
}

export type ClientCommand =
  | PromptCommand
  | StatsCommand
  | PingCommand
  | DebugCommand
  | AbortCommand
  | ResetCommand
  | SaveCommand
  | ListSessionsCommand
  | QuitCommand
  | UIResponseCommand;

// ============================================================================
// Session Events
// ============================================================================

export interface SessionEvent {
  type: string;
  data?: unknown[];
}

export interface AgentStartEvent {
  type: 'agent_start';
}

export interface AgentEndEvent {
  type: 'agent_end';
  data: [Message[]];
}

export interface TurnStartEvent {
  type: 'turn_start';
}

export interface TurnEndEvent {
  type: 'turn_end';
  data: [Message, ToolResult[]];
}

export interface MessageStartEvent {
  type: 'message_start';
  data: [Message];
}

export interface MessageUpdateEvent {
  type: 'message_update';
  data: [Message, AssistantEvent];
}

export interface MessageEndEvent {
  type: 'message_end';
  data: [Message];
}

export interface ToolExecutionStartEvent {
  type: 'tool_execution_start';
  data: [string, string, Record<string, unknown>]; // [id, name, args]
}

export interface ToolExecutionUpdateEvent {
  type: 'tool_execution_update';
  data: [string, string, Record<string, unknown>, unknown]; // [id, name, args, partial_result]
}

export interface ToolExecutionEndEvent {
  type: 'tool_execution_end';
  data: [string, string, unknown, boolean]; // [id, name, result, is_error]
}

export interface SessionErrorEvent {
  type: 'error';
  data: [string, unknown]; // [reason, partial_state]
}

export type KnownSessionEvent =
  | AgentStartEvent
  | AgentEndEvent
  | TurnStartEvent
  | TurnEndEvent
  | MessageStartEvent
  | MessageUpdateEvent
  | MessageEndEvent
  | ToolExecutionStartEvent
  | ToolExecutionUpdateEvent
  | ToolExecutionEndEvent
  | SessionErrorEvent;

// ============================================================================
// Message Types
// ============================================================================

export interface UserMessage {
  __struct__: 'Elixir.Ai.Types.UserMessage';
  role: 'user';
  content: string | ContentBlock[];
  timestamp: number;
}

/** Cost structure from Ai.Types.Cost */
export interface UsageCost {
  input?: number;
  output?: number;
  cache_read?: number;
  cache_write?: number;
  total?: number;
}

export interface AssistantMessage {
  __struct__: 'Elixir.Ai.Types.AssistantMessage';
  role: 'assistant';
  content: ContentBlock[];
  provider: string;
  model: string;
  api: string;
  /** Usage fields from Ai.Types.Usage (Lemon wire schema) */
  usage?: {
    input?: number;
    output?: number;
    cache_read?: number;
    cache_write?: number;
    total_tokens?: number;
    cost?: UsageCost;
  };
  stop_reason: 'stop' | 'length' | 'tool_use' | 'error' | 'aborted' | null;
  error_message: string | null;
  timestamp: number;
}

export interface ToolResultMessage {
  __struct__: 'Elixir.Ai.Types.ToolResultMessage';
  role: 'tool_result';
  tool_call_id: string;
  tool_name: string;
  content: ContentBlock[];
  details?: Record<string, unknown>;
  is_error: boolean;
  timestamp: number;
}

export type Message = UserMessage | AssistantMessage | ToolResultMessage;

// ============================================================================
// Content Blocks
// ============================================================================

export interface TextContent {
  __struct__: 'Elixir.Ai.Types.TextContent';
  type: 'text';
  text: string;
  text_signature?: string | null;
}

export interface ThinkingContent {
  __struct__: 'Elixir.Ai.Types.ThinkingContent';
  type: 'thinking';
  thinking: string;
  thinking_signature?: string | null;
}

export interface ToolCall {
  __struct__: 'Elixir.Ai.Types.ToolCall';
  type: 'tool_call';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface ImageContent {
  __struct__: 'Elixir.Ai.Types.ImageContent';
  type: 'image';
  data: string;
  mime_type: string;
}

export type ContentBlock = TextContent | ThinkingContent | ToolCall | ImageContent;

// ============================================================================
// Assistant Events (for message_update)
// ============================================================================

/**
 * AssistantEvent is typed as unknown[] because the Elixir server sends tuples
 * which serialize to JSON arrays. For example:
 *   {:text_delta, 0, "Hello", %{partial: true}} -> ["text_delta", 0, "Hello", {partial: true}]
 *
 * The MessageUpdateEvent already contains the updated Message object with full content,
 * so we don't need to parse these deltas - they're mainly for debugging/logging.
 */
export type AssistantEvent = unknown[];

// ============================================================================
// Tool Results
// ============================================================================

export interface ToolResult {
  __struct__: 'Elixir.AgentCore.Types.AgentToolResult';
  content: ContentBlock[];
  details?: Record<string, unknown>;
}

// ============================================================================
// UI Request Parameters
// ============================================================================

export interface SelectOption {
  label: string;
  value: string;
  description?: string | null;
}

export interface SelectParams {
  title: string;
  options: SelectOption[];
  opts?: Record<string, unknown>;
}

export interface ConfirmParams {
  title: string;
  message: string;
  opts?: Record<string, unknown>;
}

export interface InputParams {
  title: string;
  placeholder?: string | null;
  opts?: Record<string, unknown>;
}

export interface EditorParams {
  title: string;
  prefill?: string | null;
  opts?: Record<string, unknown>;
}

export type UIRequestParams = SelectParams | ConfirmParams | InputParams | EditorParams;

// ============================================================================
// Session Stats
// ============================================================================

/**
 * Session stats from CodingAgent.Session.get_stats/1
 * Note: Does NOT include token totals - those are tracked per-message in usage fields
 */
export interface SessionStats {
  session_id: string;
  message_count: number;
  turn_count: number;
  is_streaming: boolean;
  cwd: string;
  model: {
    provider: string;
    id: string;
  };
  thinking_level: string | null;
}

// ============================================================================
// Session Summary (for listing/resume)
// ============================================================================

export interface SessionSummary {
  path: string;
  id: string;
  timestamp: number;
  cwd: string;
}
