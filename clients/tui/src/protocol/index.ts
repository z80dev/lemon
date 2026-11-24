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
	ConnectionLostError,
	ControlPlaneError,
	classifyMutationError,
	ERROR_CODES,
	HandshakeError,
	MethodUnavailableError,
	type MutationOutcome,
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
export { ControlPlaneMethods, METHOD, type MethodName, OMP_METHODS } from "./methods.ts";
export * from "./omp.ts";
export type * from "./types.ts";
export {
	computeBackoffDelay,
	ReconnectingSocket,
	type ReconnectingSocketOptions,
	type SocketState,
} from "./ws.ts";
