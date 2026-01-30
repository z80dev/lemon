/**
 * Shared protocol types for Lemon debug agent RPC.
 *
 * Based on the wire format defined in LEMON_TUI_PLAN.md section 2.4
 * and implemented by scripts/debug_agent_rpc.exs.
 */
/** Optional timestamp added by the web bridge (ms since epoch). */
interface ServerTimeStamp {
    server_time?: number;
}
/** Ready message sent when server is initialized */
interface ReadyMessage {
    type: 'ready';
    cwd: string;
    model: {
        provider: string;
        id: string;
    };
    debug: boolean;
    ui: boolean;
    primary_session_id: string | null;
    active_session_id: string | null;
}
/** Event wrapper for session events */
interface EventMessage {
    type: 'event';
    event: SessionEvent;
    session_id: string;
}
/** Stats response */
interface StatsMessage {
    type: 'stats';
    stats: SessionStats;
    session_id: string;
}
/** Pong response to ping */
interface PongMessage {
    type: 'pong';
}
/** Debug info message */
interface DebugMessage {
    type: 'debug';
    message: string;
    argv?: string[];
}
/** Error message */
interface ErrorMessage {
    type: 'error';
    message: string;
    session_id?: string;
}
/** Save result message */
interface SaveResultMessage {
    type: 'save_result';
    ok: boolean;
    path?: string;
    error?: string;
    session_id?: string;
}
/** Sessions list response */
interface SessionsListMessage {
    type: 'sessions_list';
    sessions: SessionSummary[];
    error?: string;
}
/** UI request from server - requires overlay response */
interface UIRequestMessage {
    type: 'ui_request';
    id: string;
    method: 'select' | 'confirm' | 'input' | 'editor';
    params: UIRequestParams;
}
/** UI signal (notification) from server - no response needed */
interface UISignalMessage {
    type: 'ui_notify' | 'ui_status' | 'ui_widget' | 'ui_working' | 'ui_set_title' | 'ui_set_editor_text';
    params: Record<string, unknown>;
}
/** Running session info */
interface RunningSessionInfo {
    session_id: string;
    cwd: string;
    is_streaming: boolean;
}
/** Running sessions list response */
interface RunningSessionsMessage {
    type: 'running_sessions';
    sessions: RunningSessionInfo[];
    error?: string | null;
}
/** Models list response */
interface ModelsListMessage {
    type: 'models_list';
    providers: Array<{
        id: string;
        models: Array<{
            id: string;
            name?: string;
        }>;
    }>;
    error?: string | null;
}
/** Session started notification */
interface SessionStartedMessage {
    type: 'session_started';
    session_id: string;
    cwd: string;
    model: {
        provider: string;
        id: string;
    };
}
/** Session closed notification */
interface SessionClosedMessage {
    type: 'session_closed';
    session_id: string;
    reason: 'normal' | 'not_found' | 'error';
}
/** Active session changed notification */
interface ActiveSessionMessage {
    type: 'active_session';
    session_id: string | null;
}
type ServerMessage = ReadyMessage | EventMessage | StatsMessage | PongMessage | DebugMessage | ErrorMessage | SaveResultMessage | SessionsListMessage | UIRequestMessage | UISignalMessage | RunningSessionsMessage | ModelsListMessage | SessionStartedMessage | SessionClosedMessage | ActiveSessionMessage;
interface BridgeStatusMessage {
    type: 'bridge_status';
    state: 'starting' | 'running' | 'stopped' | 'error';
    message?: string;
    pid?: number | null;
}
interface BridgeErrorMessage {
    type: 'bridge_error';
    message: string;
    detail?: unknown;
}
interface BridgeStderrMessage {
    type: 'bridge_stderr';
    message: string;
}
type BridgeMessage = BridgeStatusMessage | BridgeErrorMessage | BridgeStderrMessage;
/** Messages that the web UI can receive via WebSocket. */
type WireServerMessage = (ServerMessage | BridgeMessage) & ServerTimeStamp;
interface PromptCommand {
    type: 'prompt';
    text: string;
    session_id?: string;
}
interface StatsCommand {
    type: 'stats';
    session_id?: string;
}
interface PingCommand {
    type: 'ping';
}
interface DebugCommand {
    type: 'debug';
}
interface AbortCommand {
    type: 'abort';
    session_id?: string;
}
interface ResetCommand {
    type: 'reset';
    session_id?: string;
}
interface SaveCommand {
    type: 'save';
    session_id?: string;
}
interface ListSessionsCommand {
    type: 'list_sessions';
}
interface QuitCommand {
    type: 'quit';
}
interface UIResponseCommand {
    type: 'ui_response';
    id: string;
    result: unknown;
    error: string | null;
}
/** Start a new session */
interface StartSessionCommand {
    type: 'start_session';
    cwd?: string;
    model?: string;
    system_prompt?: string;
    session_file?: string;
    parent_session?: string;
}
/** Close a running session */
interface CloseSessionCommand {
    type: 'close_session';
    session_id: string;
}
/** List running sessions */
interface ListRunningSessionsCommand {
    type: 'list_running_sessions';
}
/** List known models/providers */
interface ListModelsCommand {
    type: 'list_models';
}
/** Set the active session */
interface SetActiveSessionCommand {
    type: 'set_active_session';
    session_id: string;
}
type ClientCommand = PromptCommand | StatsCommand | PingCommand | DebugCommand | AbortCommand | ResetCommand | SaveCommand | ListSessionsCommand | QuitCommand | UIResponseCommand | StartSessionCommand | CloseSessionCommand | ListRunningSessionsCommand | ListModelsCommand | SetActiveSessionCommand;
interface SessionEvent {
    type: string;
    data?: unknown[];
}
interface AgentStartEvent {
    type: 'agent_start';
}
interface AgentEndEvent {
    type: 'agent_end';
    data: [Message[]];
}
interface TurnStartEvent {
    type: 'turn_start';
}
interface TurnEndEvent {
    type: 'turn_end';
    data: [Message, ToolResult[]];
}
interface MessageStartEvent {
    type: 'message_start';
    data: [Message];
}
interface MessageUpdateEvent {
    type: 'message_update';
    data: [Message, AssistantEvent];
}
interface MessageEndEvent {
    type: 'message_end';
    data: [Message];
}
interface ToolExecutionStartEvent {
    type: 'tool_execution_start';
    data: [string, string, Record<string, unknown>];
}
interface ToolExecutionUpdateEvent {
    type: 'tool_execution_update';
    data: [string, string, Record<string, unknown>, unknown];
}
interface ToolExecutionEndEvent {
    type: 'tool_execution_end';
    data: [string, string, unknown, boolean];
}
interface SessionErrorEvent {
    type: 'error';
    data: [string, unknown];
}
type KnownSessionEvent = AgentStartEvent | AgentEndEvent | TurnStartEvent | TurnEndEvent | MessageStartEvent | MessageUpdateEvent | MessageEndEvent | ToolExecutionStartEvent | ToolExecutionUpdateEvent | ToolExecutionEndEvent | SessionErrorEvent;
interface UserMessage {
    __struct__: 'Elixir.Ai.Types.UserMessage';
    role: 'user';
    content: string | ContentBlock[];
    timestamp: number;
}
/** Cost structure from Ai.Types.Cost */
interface UsageCost {
    input?: number;
    output?: number;
    cache_read?: number;
    cache_write?: number;
    total?: number;
}
interface AssistantMessage {
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
interface ToolResultMessage {
    __struct__: 'Elixir.Ai.Types.ToolResultMessage';
    role: 'tool_result';
    tool_call_id: string;
    tool_name: string;
    content: ContentBlock[];
    details?: Record<string, unknown>;
    is_error: boolean;
    timestamp: number;
}
type Message = UserMessage | AssistantMessage | ToolResultMessage;
interface TextContent {
    __struct__: 'Elixir.Ai.Types.TextContent';
    type: 'text';
    text: string;
    text_signature?: string | null;
}
interface ThinkingContent {
    __struct__: 'Elixir.Ai.Types.ThinkingContent';
    type: 'thinking';
    thinking: string;
    thinking_signature?: string | null;
}
interface ToolCall {
    __struct__: 'Elixir.Ai.Types.ToolCall';
    type: 'tool_call';
    id: string;
    name: string;
    arguments: Record<string, unknown>;
}
interface ImageContent {
    __struct__: 'Elixir.Ai.Types.ImageContent';
    type: 'image';
    data: string;
    mime_type: string;
}
type ContentBlock = TextContent | ThinkingContent | ToolCall | ImageContent;
/**
 * AssistantEvent is typed as unknown[] because the Elixir server sends tuples
 * which serialize to JSON arrays. For example:
 *   {:text_delta, 0, "Hello", %{partial: true}} -> ["text_delta", 0, "Hello", {partial: true}]
 *
 * The MessageUpdateEvent already contains the updated Message object with full content,
 * so we don't need to parse these deltas - they're mainly for debugging/logging.
 */
type AssistantEvent = unknown[];
interface ToolResult {
    __struct__: 'Elixir.AgentCore.Types.AgentToolResult';
    content: ContentBlock[];
    details?: Record<string, unknown>;
}
interface SelectOption {
    label: string;
    value: string;
    description?: string | null;
}
interface SelectParams {
    title: string;
    options: SelectOption[];
    opts?: Record<string, unknown>;
}
interface ConfirmParams {
    title: string;
    message: string;
    opts?: Record<string, unknown>;
}
interface InputParams {
    title: string;
    placeholder?: string | null;
    opts?: Record<string, unknown>;
}
interface EditorParams {
    title: string;
    prefill?: string | null;
    opts?: Record<string, unknown>;
}
type UIRequestParams = SelectParams | ConfirmParams | InputParams | EditorParams;
/**
 * Session stats from CodingAgent.Session.get_stats/1
 * Note: Does NOT include token totals - those are tracked per-message in usage fields
 */
interface SessionStats {
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
interface SessionSummary {
    path: string;
    id: string;
    timestamp: number;
    cwd: string;
}

/**
 * JSON line decoder/encoder helpers for Lemon RPC.
 */
interface JsonLineParserOptions {
    onMessage: (value: unknown) => void;
    onError?: (error: Error, rawLine: string) => void;
}
declare class JsonLineDecoder {
    private readonly opts;
    private buffer;
    constructor(opts: JsonLineParserOptions);
    write(chunk: string | Buffer): void;
    flush(): void;
    private handleLine;
}
declare function encodeJsonLine(payload: unknown): string;

export { type AbortCommand, type ActiveSessionMessage, type AgentEndEvent, type AgentStartEvent, type AssistantEvent, type AssistantMessage, type BridgeErrorMessage, type BridgeMessage, type BridgeStatusMessage, type BridgeStderrMessage, type ClientCommand, type CloseSessionCommand, type ConfirmParams, type ContentBlock, type DebugCommand, type DebugMessage, type EditorParams, type ErrorMessage, type EventMessage, type ImageContent, type InputParams, JsonLineDecoder, type JsonLineParserOptions, type KnownSessionEvent, type ListModelsCommand, type ListRunningSessionsCommand, type ListSessionsCommand, type Message, type MessageEndEvent, type MessageStartEvent, type MessageUpdateEvent, type ModelsListMessage, type PingCommand, type PongMessage, type PromptCommand, type QuitCommand, type ReadyMessage, type ResetCommand, type RunningSessionInfo, type RunningSessionsMessage, type SaveCommand, type SaveResultMessage, type SelectOption, type SelectParams, type ServerMessage, type ServerTimeStamp, type SessionClosedMessage, type SessionErrorEvent, type SessionEvent, type SessionStartedMessage, type SessionStats, type SessionSummary, type SessionsListMessage, type SetActiveSessionCommand, type StartSessionCommand, type StatsCommand, type StatsMessage, type TextContent, type ThinkingContent, type ToolCall, type ToolExecutionEndEvent, type ToolExecutionStartEvent, type ToolExecutionUpdateEvent, type ToolResult, type ToolResultMessage, type TurnEndEvent, type TurnStartEvent, type UIRequestMessage, type UIRequestParams, type UIResponseCommand, type UISignalMessage, type UsageCost, type UserMessage, type WireServerMessage, encodeJsonLine };
