#if DEBUG
import Foundation

extension FixtureWorld {
    func instance(controllerDown: Bool = false, runtimeRunning: Bool = false) -> FixtureJSON {
        let ms = now.timeIntervalSince1970 * 1000
        return [
            "measuredAtMs": ms,
            "backend": ["version": "0.1.0", "apiVersion": 1, "startedAtMs": ms - 3_600_000, "publicUrl": "https://desktop.tailnet.ts.net"],
            "controller": ["url": "ws://127.0.0.1:4040/ws", "state": controllerDown ? "reconnecting" : "connected", "connectedAtMs": controllerDown ? NSNull() : ms - 3_600_000, "lastDisconnectedAtMs": controllerDown ? ms - 15_000 : NSNull(), "lastError": controllerDown ? ["code": "connection_refused", "message": "Nothing is listening on the local Lemon controller port.", "atMs": ms - 15_000] : NSNull(), "nextRetryAtMs": controllerDown ? ms + 12_000 : NSNull(), "methodCount": controllerDown ? 0 : 42] as FixtureJSON,
            "lemon": controllerDown ? NSNull() : ["version": "2026.10.15", "build": NSNull(), "providers": NSNull(), "uptimeMs": 3_600_000, "memoryMb": 256.5, "connections": ["active": 3, "operators": 1, "nodes": 2], "runs": ["active": 1, "queued": 2, "completedToday": 14], "activeSessions": 7, "channels": ["configured": ["telegram", "slack"], "connected": ["telegram"], "details": []], "skills": ["installed": 10, "enabled": 8], "nodes": ["total": 3, "online": 2]],
            "lemonUnavailableReason": controllerDown ? "Start Lemon to see live instance details." : NSNull(),
            "runtime": ["actions": ["start", "stop", "restart"], "via": "launcher", "reason": NSNull(), "operation": runtimeRunning ? ["id": "operation_FixtureRestart", "action": "restart", "state": "running", "startedAtMs": ms - 3000, "completedAtMs": NSNull(), "exitCode": NSNull(), "output": "Stopping Lemon…\nStarting Lemon…\nWaiting for the controller link…"] as FixtureJSON : NSNull()] as FixtureJSON
        ]
    }
}
#endif
