#if DEBUG
import Foundation

/// DEBUG-only seams for the fixture/snapshot harness. They touch client state only:
/// no production code path calls them and they are compiled out of Release builds.
extension LemonBotStore {
    /// Routes every HTTP read/mutation through `session` (a `URLProtocol` stub). Must be called before `restoreAccount`.
    public func installFixtureSession(_ session: URLSession) { httpSession = session }

    /// Cancels any websocket attempt and pins the connection to `online`, so a fixture workspace never
    /// flips to "connecting"/"disconnected" while a snapshot settles. Client state only.
    public func pinFixtureOnline() {
        stopSocket()
        connectionState = "online"
        errorMessage = nil
    }
    public func pinFixtureConnectionFailure(_ error: Error, nextRetry: Date? = nil) {
        stopSocket(); connectionState = "disconnected"
        lastConnectionAttemptAt = Date(); nextRetryAt = nextRetry
        recordConnectionFailure(error)
    }
    public func pinFixtureControllerDown(_ status: InstanceStatus) {
        pinFixtureOnline(); instanceStatus = status
        capabilities?.controlConnected = false; updateControllerIssue()
    }
}
#endif
