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
- `Sessions`: session explorer + deep session detail + run history
- `Runners`: runner lifecycle timelines, stuck-run alerts, engine load
- `Run`: run graph, introspection timeline, tool/task internals
- `Tasks`: task tree by run
- `Cron`: cron jobs and run history
- `Events`: live raw event stream

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
