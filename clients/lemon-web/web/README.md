# Lemon Web Client

React/Vite frontend for Lemon chat and monitoring.

## Modes

- Chat mode (default): `/`
- Monitoring mode: `/monitor` or `/?monitor`

Monitoring mode subscribes to control-plane events and loads rich runtime state from:

- `status`
- `introspection.snapshot`
- `agent.directory.list`
- `sessions.list` / `sessions.active.list`
- `runs.active.list` / `runs.recent.list`
- `tasks.active.list` / `tasks.recent.list`
- `session.detail` (selected and hot active sessions)
- `run.introspection.list` / `run.graph.get` (run inspector)
- `channels.status`
- `transports.status`
- `skills.status`
- `cron.status` / `cron.list`

It also refreshes monitoring data every 15 seconds while connected (5 seconds when active runs are present) so session/agent/runner/task/tool status stays current even when no new events are emitted.

Channel health treats `connected`, `running`, `enabled`, and `active` as live states in the UI.
Runner engine summaries include both run engines and task engines (when present).

## Monitoring screens

- `Overview`: health, infra, engine/task/tool summaries
- `Sessions`: session workspace with live run/task state, spawned-agent visibility, and chat-style run transcript
- `Runners`: runner lifecycle timelines, stuck-run alerts, engine load
- `Run`: run graph, introspection timeline, tool/task internals
- `Tasks`: task tree by run
- `Cron`: cron jobs and run history
- `Events`: live raw event stream (dedicated tab; no always-on side rail)

Session list behavior is opinionated by default:
- `Focus` scope prioritizes active/recent/high-signal sessions.
- `System: OFF` hides cron/heartbeat/delegate noise sessions unless explicitly enabled.
- Session history preserves richer metadata from directory/snapshot sources even when `sessions.list` returns minimal records.

## Local development

```bash
cd clients/lemon-web/web
npm install
npm run dev
```

## Build

```bash
npm run build
```
