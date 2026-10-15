#if DEBUG
import Foundation

extension FixtureWorld {
    func instance(controllerDown: Bool = false, runtimeRunning: Bool = false) -> FixtureJSON {
        let ms = now.timeIntervalSince1970 * 1000
        let launcher = !runtimeRunning && !controllerDown
        let providers: [FixtureJSON] = [
            ["id": "anthropic", "configured": true, "credential": "present", "isDefault": true, "lastError": NSNull()],
            ["id": "openai", "configured": true, "credential": "missing", "isDefault": false, "lastError": ["message": "A provider key is required to use this model.", "atMs": ms - 300_000]],
            ["id": "ollama", "configured": true, "credential": "not_required", "isDefault": false, "lastError": NSNull()]
        ]
        let channels: FixtureJSON = [
            "configured": ["telegram", "slack", "discord"], "connected": ["telegram"],
            "details": [
                ["id": "telegram", "state": "connected", "lastError": NSNull()],
                ["id": "slack", "state": "error", "lastError": ["message": "Slack disconnected. Check the app connection on the Lemon host.", "atMs": ms - 120_000]],
                ["id": "discord", "state": "configured", "lastError": NSNull()]
            ] as [FixtureJSON]
        ]
        return [
            "measuredAtMs": ms,
            "backend": ["version": "0.1.0", "apiVersion": 1, "startedAtMs": ms - 3_600_000, "publicUrl": "https://desktop.tailnet.ts.net"],
            "controller": ["url": launcher ? "ws://127.0.0.1:4040/ws" : "wss://lemon.tailnet.ts.net/ws", "state": controllerDown ? "reconnecting" : "connected", "connectedAtMs": controllerDown ? NSNull() : ms - 3_600_000, "lastDisconnectedAtMs": controllerDown ? ms - 15_000 : NSNull(), "lastError": controllerDown ? ["code": "connection_refused", "message": "The remote Lemon controller isn’t accepting connections.", "atMs": ms - 15_000] : NSNull(), "nextRetryAtMs": controllerDown ? ms + 12_000 : NSNull(), "methodCount": controllerDown ? 0 : 42] as FixtureJSON,
            "lemon": controllerDown ? NSNull() : ["version": "2026.10.15", "build": ["runtimeMode": "release-runtime", "channel": "preview", "commit": "abc123456789"], "providers": providers, "uptimeMs": 3_600_000, "memoryMb": 256.5, "connections": ["active": 3, "operators": 1, "nodes": 2], "runs": ["active": 1, "queued": 2, "completedToday": 14], "activeSessions": 7, "channels": channels, "skills": ["installed": 10, "enabled": 8], "nodes": ["total": 3, "online": 2]],
            "lemonUnavailableReason": controllerDown ? "Lemon is unavailable. Start it on its host to restore live details." : NSNull(),
            "runtime": ["actions": controllerDown ? [] : launcher ? ["stop", "restart"] : ["restart", "stop"], "via": launcher ? "launcher" : "controller", "reason": launcher ? NSNull() : "Start is unavailable remotely. If Lemon stops, start it on the Lemon host.", "operation": runtimeRunning ? ["id": "operation_FixtureRestart", "action": "restart", "state": "running", "startedAtMs": ms - 3000, "completedAtMs": NSNull(), "exitCode": NSNull(), "output": "Remote restart accepted.\nWaiting for Lemon to reconnect…"] as FixtureJSON : NSNull()] as FixtureJSON
        ]
    }
}
#endif
