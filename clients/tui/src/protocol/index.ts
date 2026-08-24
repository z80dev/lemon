/** Public surface of the protocol layer. */

export {
	acceptDeltaSeq,
	ControlPlaneClient,
	type ControlPlaneClientOptions,
	DEFAULT_QUEUEABLE_METHODS,
	DEFAULT_REQUEST_TIMEOUT_MS,
	DEFAULT_WS_URL,
	defaultClientId,
	type QueuedRequestView,
	type RequestOptions,
} from "./client.ts";
export {
	ControlPlaneError,
	ERROR_CODES,
	HandshakeError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
	type ServerErrorCode,
} from "./errors.ts";
export {
	type ClientFrame,
	DEFAULT_POLICY,
	decodeFrame,
	type EventFrame,
	encodeFrame,
	FrameDecodeError,
	type HelloOkFrame,
	isEventFrame,
	isHelloOkFrame,
	isResFrame,
	isServerFrame,
	makeReq,
	type ProtocolErrorPayload,
	type ReqFrame,
	type ResFrame,
	type ServerFrame,
	tryDecodeFrame,
} from "./frames.ts";
export { ControlPlaneMethods, METHOD, type MethodName } from "./methods.ts";
export type * from "./types.ts";
export {
	computeBackoffDelay,
	ReconnectingSocket,
	type ReconnectingSocketOptions,
	type SocketState,
} from "./ws.ts";
