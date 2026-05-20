defmodule LemonControlPlane.Protocol.Schemas do
  @moduledoc """
  JSON schema definitions for control plane methods.

  Each method can define a schema for request validation.
  Schemas are simple maps that specify required fields and types.
  """

  @schemas %{
    # Connection/handshake
    "connect" => %{
      optional: %{
        "minProtocol" => :integer,
        "maxProtocol" => :integer,
        "client" => :map,
        "auth" => :map,
        "role" => :string,
        "scopes" => :list
      }
    },

    # System/health methods
    "health" => %{optional: %{}},
    "status" => %{optional: %{}},
    "introspection.snapshot" => %{
      optional: %{
        "agentId" => :string,
        "route" => :map,
        "limit" => :integer,
        "sessionLimit" => :integer,
        "activeLimit" => :integer,
        "includeAgents" => :boolean,
        "includeSessions" => :boolean,
        "includeActiveSessions" => :boolean,
        "includeChannels" => :boolean,
        "includeTransports" => :boolean
      }
    },
    "logs.tail" => %{
      optional: %{
        "limit" => :integer,
        "level" => :string,
        "lines" => :integer,
        "filter" => :string
      }
    },
    "events.subscribe" => %{
      optional: %{
        "topics" => [:list, :string],
        "runId" => :string,
        "run_id" => :string
      }
    },
    "events.unsubscribe" => %{
      optional: %{
        "topics" => [:list, :string],
        "runId" => :string,
        "run_id" => :string
      }
    },
    "events.subscriptions.list" => %{optional: %{}},
    "events.ingest" => %{
      required_any: [["eventType", "event_type"]],
      optional: %{
        "eventType" => :string,
        "event_type" => :string,
        "payload" => :map,
        "target" => :string
      }
    },

    # Channel methods
    "channels.status" => %{
      optional: %{
        "projectDir" => :string,
        "project_dir" => :string
      }
    },
    "transports.status" => %{optional: %{}},
    "channels.logout" => %{
      optional: %{
        "channelId" => :string
      }
    },

    # Model methods
    "models.list" => %{
      optional: %{
        "discoverOpenAI" => :boolean
      }
    },
    "providers.status" => %{
      optional: %{
        "provider" => :string,
        "providers" => :list,
        "includeCatalog" => :boolean,
        "include_catalog" => :boolean,
        "requestedProvider" => :string,
        "requested_provider" => :string,
        "requestedModel" => :string,
        "requested_model" => :string,
        "model" => :string,
        "fallbackProviders" => :list,
        "fallback_providers" => :list,
        "projectDir" => :string,
        "project_dir" => :string,
        "cwd" => :string
      }
    },
    "extensions.status" => %{
      optional: %{
        "cwd" => :string,
        "projectDir" => :string,
        "project_dir" => :string,
        "extensionPaths" => :list,
        "extension_paths" => :list
      }
    },
    "memory.status" => %{optional: %{}},

    # Agent methods
    "agents.list" => %{optional: %{}},
    "agents.files.list" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "agents.files.get" => %{
      required: %{
        "fileName" => :string
      },
      optional: %{
        "agentId" => :string
      }
    },
    "agents.files.set" => %{
      required: %{
        "fileName" => :string,
        "content" => :string
      },
      optional: %{
        "agentId" => :string,
        "type" => :string
      }
    },
    "agent" => %{
      required: %{
        "prompt" => :string
      },
      optional: %{
        "sessionKey" => :string,
        "agentId" => :string,
        "queueMode" => :string,
        "engineId" => :string,
        "model" => :string
      }
    },
    "agent.identity.get" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "agent.wait" => %{
      optional: %{
        "runId" => :string,
        "timeoutMs" => :integer
      }
    },
    "agent.progress" => %{
      required: %{
        "sessionId" => :string
      },
      optional: %{
        "cwd" => :string,
        "runId" => :string,
        "sessionKey" => :string,
        "agentId" => :string
      }
    },
    "agent.inbox.send" => %{
      required: %{
        "prompt" => :string
      },
      optional: %{
        "agentId" => :string,
        "session" => :string,
        "sessionKey" => :string,
        "sessionTag" => :string,
        "queueMode" => :string,
        "engineId" => :string,
        "model" => :string,
        "cwd" => :string,
        "toolPolicy" => :map,
        "meta" => :map,
        "to" => :any,
        "endpoint" => :any,
        "route" => :any,
        "deliverTo" => :any,
        "accountId" => :string,
        "peerKind" => :string
      }
    },
    "agent.directory.list" => %{
      optional: %{
        "agentId" => :string,
        "includeSessions" => :boolean,
        "limit" => :integer,
        "route" => :map
      }
    },
    "agent.targets.list" => %{
      optional: %{
        "channelId" => :string,
        "accountId" => :string,
        "agentId" => :string,
        "query" => :string,
        "limit" => :integer
      }
    },
    "agent.endpoints.list" => %{
      optional: %{
        "agentId" => :string,
        "limit" => :integer
      }
    },
    "agent.endpoints.set" => %{
      required: %{
        "name" => :string
      },
      optional: %{
        "agentId" => :string,
        "target" => :any,
        "to" => :any,
        "endpoint" => :any,
        "route" => :any,
        "description" => :string,
        "accountId" => :string,
        "peerKind" => :string
      }
    },
    "agent.endpoints.delete" => %{
      required: %{
        "name" => :string
      },
      optional: %{
        "agentId" => :string
      }
    },
    "goal.set" => %{
      required: %{
        "sessionKey" => :string,
        "objective" => :string
      },
      optional: %{
        "agentId" => :string,
        "runId" => :string,
        "maxContinuations" => :integer
      }
    },
    "goal.status" => %{
      optional: %{
        "sessionKey" => :string,
        "agentId" => :string,
        "status" => :string,
        "limit" => :integer
      }
    },
    "goal.pause" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "runId" => :string
      }
    },
    "goal.resume" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "runId" => :string
      }
    },
    "goal.continue" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "runId" => :string,
        "maxContinuations" => :integer,
        "judgeModel" => :string,
        "judgeFailurePolicy" => :string,
        "model" => :string
      }
    },
    "goal.loop.once" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "runId" => :string,
        "maxContinuations" => :integer,
        "model" => :string
      }
    },
    "goal.loop.start" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "runId" => :string,
        "maxTicks" => :integer,
        "maxContinuations" => :integer,
        "intervalMs" => :integer,
        "waitTimeoutMs" => :integer,
        "judgeModel" => :string,
        "judgeFailurePolicy" => :string,
        "model" => :string,
        "auto" => :boolean
      }
    },
    "goal.loop.stop" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "goal.loop.status" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "goal.clear" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "kanban.board.create" => %{
      required: %{
        "name" => :string
      },
      optional: %{
        "workspace" => :string,
        "owner" => :string,
        "columns" => :list,
        "meta" => :map
      }
    },
    "kanban.board.list" => %{
      optional: %{
        "status" => :string,
        "owner" => :string,
        "workspace" => :string,
        "limit" => :integer
      }
    },
    "kanban.board.get" => %{
      required: %{
        "boardId" => :string
      },
      optional: %{
        "limit" => :integer
      }
    },
    "kanban.board.archive" => %{
      required: %{
        "boardId" => :string
      }
    },
    "kanban.task.create" => %{
      required: %{
        "boardId" => :string,
        "title" => :string
      },
      optional: %{
        "description" => :string,
        "status" => :string,
        "priority" => :string,
        "assignee" => :string,
        "workerProfile" => :string,
        "sessionKey" => :string,
        "runId" => :string,
        "dependsOn" => :list,
        "meta" => :map
      }
    },
    "kanban.task.update" => %{
      required: %{
        "taskId" => :string
      },
      optional: %{
        "title" => :string,
        "description" => :string,
        "status" => :string,
        "priority" => :string,
        "assignee" => :string,
        "workerProfile" => :string,
        "sessionKey" => :string,
        "runId" => :string,
        "dependsOn" => :list,
        "meta" => :map
      }
    },
    "kanban.task.comment" => %{
      required: %{
        "taskId" => :string,
        "body" => :string
      },
      optional: %{
        "author" => :string
      }
    },
    "kanban.dispatcher.start" => %{
      required: %{
        "boardId" => :string
      },
      optional: %{
        "intervalMs" => :integer,
        "maxConcurrency" => :integer,
        "leaseMs" => :integer,
        "workerId" => :string,
        "workerProfile" => :string
      }
    },
    "kanban.dispatcher.status" => %{
      required: %{
        "boardId" => :string
      }
    },
    "kanban.dispatcher.stop" => %{
      required: %{
        "boardId" => :string
      }
    },

    # Skill methods
    "skills.status" => %{
      optional: %{
        "cwd" => :string
      }
    },
    "skills.bins" => %{
      optional: %{
        "cwd" => :string
      }
    },
    "skills.install" => %{
      required: %{
        "skillKey" => :string
      },
      optional: %{
        "cwd" => :string,
        "installId" => :string,
        "timeoutMs" => :integer
      }
    },
    "skills.update" => %{
      required: %{
        "skillKey" => :string
      },
      optional: %{
        "cwd" => :string,
        "enabled" => :boolean,
        "env" => :map
      }
    },

    # Session methods
    "sessions.list" => %{
      optional: %{
        "limit" => :integer,
        "offset" => :integer,
        "agentId" => :string
      }
    },
    "sessions.preview" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "limit" => :integer
      }
    },
    "sessions.patch" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "toolPolicy" => :map,
        "model" => :string,
        "thinkingLevel" => :string
      }
    },
    "sessions.reset" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "sessions.delete" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "sessions.compact" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "sessions.active" => %{
      required: %{
        "sessionKey" => :string
      }
    },
    "sessions.active.list" => %{
      optional: %{
        "agentId" => :string,
        "limit" => :integer,
        "route" => :map
      }
    },
    "session.detail" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "limit" => :integer,
        "historyLimit" => :integer,
        "eventLimit" => :integer,
        "toolCallLimit" => :integer,
        "includeFullText" => :boolean,
        "includeRawEvents" => :boolean,
        "includeRunRecord" => :boolean
      }
    },

    # Monitoring methods
    "runs.active.list" => %{
      optional: %{
        "agentId" => :string,
        "sessionKey" => :string,
        "limit" => :integer
      }
    },
    "runs.recent.list" => %{
      optional: %{
        "agentId" => :string,
        "sessionKey" => :string,
        "status" => :string,
        "limit" => :integer
      }
    },
    "run.graph.get" => %{
      required: %{
        "runId" => :string
      },
      optional: %{
        "maxDepth" => :integer,
        "childLimit" => :integer,
        "includeRunRecord" => :boolean,
        "includeRunEvents" => :boolean,
        "runEventLimit" => :integer,
        "includeIntrospection" => :boolean,
        "introspectionLimit" => :integer
      }
    },
    "run.introspection.list" => %{
      required: %{
        "runId" => :string
      },
      optional: %{
        "limit" => :integer,
        "eventTypes" => :list,
        "sinceMs" => :integer,
        "untilMs" => :integer,
        "includeRunRecord" => :boolean,
        "includeRunEvents" => :boolean,
        "runEventLimit" => :integer
      }
    },
    "tasks.active.list" => %{
      optional: %{
        "runId" => :string,
        "agentId" => :string,
        "limit" => :integer,
        "includeEvents" => :boolean,
        "includeRecord" => :boolean,
        "eventLimit" => :integer
      }
    },
    "tasks.recent.list" => %{
      optional: %{
        "runId" => :string,
        "agentId" => :string,
        "status" => :string,
        "limit" => :integer,
        "includeEvents" => :boolean,
        "includeRecord" => :boolean,
        "eventLimit" => :integer
      }
    },

    # Cron methods
    "cron.list" => %{
      optional: %{
        "agentId" => :string,
        "includeTargetText" => :boolean
      }
    },
    "cron.status" => %{optional: %{}},
    "cron.add" => %{
      required: %{
        "name" => :string,
        "schedule" => :string
      },
      optional: %{
        "agentId" => :string,
        "sessionKey" => :string,
        "prompt" => :string,
        "command" => :string,
        "cwd" => :string,
        "env" => :map,
        "enabled" => :boolean,
        "timezone" => :string,
        "jitterSec" => :integer,
        "timeoutMs" => :integer,
        "maxRetries" => :integer,
        "retryBackoffMs" => :integer,
        "meta" => :map
      }
    },
    "cron.update" => %{
      required: %{
        "id" => :string
      },
      optional: %{
        "name" => :string,
        "schedule" => :string,
        "enabled" => :boolean,
        "prompt" => :string,
        "command" => :string,
        "cwd" => :string,
        "env" => :map,
        "timezone" => :string,
        "jitterSec" => :integer,
        "timeoutMs" => :integer,
        "maxRetries" => :integer,
        "retryBackoffMs" => :integer
      }
    },
    "cron.pause" => %{
      required: %{
        "id" => :string
      }
    },
    "cron.resume" => %{
      required: %{
        "id" => :string
      }
    },
    "cron.abort" => %{
      required: %{
        "runId" => :string
      }
    },
    "cron.remove" => %{
      required: %{
        "id" => :string
      }
    },
    "cron.run" => %{
      required: %{
        "id" => :string
      }
    },
    "cron.runs" => %{
      required: %{
        "id" => :string
      },
      optional: %{
        "limit" => :integer,
        "status" => :string,
        "sinceMs" => :integer,
        "includeOutput" => :boolean,
        "includeMeta" => :boolean,
        "includeRunRecord" => :boolean,
        "includeIntrospection" => :boolean,
        "introspectionLimit" => :integer
      }
    },
    "cron.audit" => %{
      optional: %{
        "jobId" => :string,
        "runId" => :string,
        "cronRunId" => :string,
        "action" => :string,
        "sinceMs" => :integer,
        "limit" => :integer
      }
    },

    # Chat methods
    "chat.history" => %{
      optional: %{
        "sessionKey" => :string,
        "limit" => :integer,
        "beforeId" => :string,
        "includeFullText" => :boolean
      }
    },
    "chat.send" => %{
      required: %{
        "sessionKey" => :string,
        "prompt" => :string
      },
      optional: %{
        "agentId" => :string,
        "queueMode" => :string
      }
    },
    "chat.abort" => %{
      optional: %{
        "sessionKey" => :string,
        "runId" => :string
      }
    },

    # Browser methods
    "browser.status" => %{
      optional: %{
        "projectDir" => :string,
        "project_dir" => :string,
        "limit" => :integer
      }
    },
    "browser.request" => %{
      required: %{
        "method" => :string
      },
      optional: %{
        "args" => :map,
        "nodeId" => :string,
        "timeoutMs" => :integer,
        "await" => :boolean,
        "local" => :boolean
      }
    },
    "media.status" => %{
      optional: %{
        "projectDir" => :string,
        "project_dir" => :string,
        "jobsDir" => :string,
        "jobs_dir" => :string,
        "artifactsDir" => :string,
        "artifacts_dir" => :string,
        "limit" => :integer
      }
    },
    "readiness.status" => %{
      optional: %{
        "projectDir" => :string,
        "project_dir" => :string,
        "limit" => :integer
      }
    },
    "proofs.status" => %{
      optional: %{
        "projectDir" => :string,
        "project_dir" => :string,
        "limit" => :integer
      }
    },

    # Checkpoint methods
    "checkpoint.status" => %{
      optional: %{
        "checkpointDir" => :string,
        "checkpoint_dir" => :string,
        "limit" => :integer,
        "eventLimit" => :integer,
        "event_limit" => :integer,
        "runId" => :string,
        "run_id" => :string,
        "sessionKey" => :string,
        "session_key" => :string,
        "agentId" => :string,
        "agent_id" => :string
      }
    },
    "checkpoint.diff" => %{
      optional: %{
        "checkpointId" => :string,
        "checkpoint_id" => :string,
        "paths" => :array
      }
    },
    "checkpoint.restore" => %{
      optional: %{
        "checkpointId" => :string,
        "checkpoint_id" => :string,
        "paths" => :array,
        "runId" => :string,
        "run_id" => :string,
        "sessionKey" => :string,
        "session_key" => :string,
        "agentId" => :string,
        "agent_id" => :string,
        "parentRunId" => :string,
        "parent_run_id" => :string
      }
    },
    "lsp.diagnostics.status" => %{
      optional: %{
        "diagnosticsTimeoutMs" => :integer,
        "diagnostics_timeout_ms" => :integer
      }
    },
    "lsp.server.start" => %{
      required: %{
        "serverId" => :string
      },
      optional: %{
        "server_id" => :string,
        "sessionId" => :string,
        "session_id" => :string,
        "cwd" => :string
      }
    },
    "lsp.server.request" => %{
      required: %{
        "sessionId" => :string,
        "method" => :string
      },
      optional: %{
        "session_id" => :string,
        "params" => :any,
        "timeoutMs" => :integer,
        "timeout_ms" => :integer
      }
    },
    "lsp.server.initialize" => %{
      required: %{
        "sessionId" => :string
      },
      optional: %{
        "session_id" => :string,
        "params" => :any,
        "timeoutMs" => :integer,
        "timeout_ms" => :integer
      }
    },
    "lsp.document.open" => %{
      required: %{
        "sessionId" => :string,
        "uri" => :string,
        "languageId" => :string,
        "text" => :string
      },
      optional: %{
        "session_id" => :string,
        "language_id" => :string,
        "version" => :integer
      }
    },
    "lsp.document.change" => %{
      required: %{
        "sessionId" => :string,
        "uri" => :string,
        "text" => :string
      },
      optional: %{
        "session_id" => :string,
        "version" => :integer
      }
    },
    "lsp.document.close" => %{
      required: %{
        "sessionId" => :string,
        "uri" => :string
      },
      optional: %{
        "session_id" => :string
      }
    },
    "lsp.server.stop" => %{
      required: %{
        "sessionId" => :string
      },
      optional: %{
        "session_id" => :string
      }
    },

    # Execution/approval methods
    "exec.approvals.get" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "exec.approvals.set" => %{
      required: %{
        "policy" => :map
      },
      optional: %{
        "agentId" => :string
      }
    },
    "exec.approvals.node.get" => %{
      required: %{
        "nodeId" => :string
      }
    },
    "exec.approvals.node.set" => %{
      required: %{
        "nodeId" => :string,
        "policy" => :map
      }
    },
    "exec.approval.request" => %{
      required: %{
        "runId" => :string,
        "tool" => :string,
        "rationale" => :string
      },
      optional: %{
        "sessionKey" => :string,
        "agentId" => :string,
        "expiresInMs" => :integer
      }
    },
    "exec.approval.resolve" => %{
      required: %{
        "approvalId" => :string,
        "decision" => :string
      }
    },

    # Node methods
    "node.pair.request" => %{
      required: %{
        "nodeType" => :string,
        "nodeName" => :string
      },
      optional: %{
        "expiresInMs" => :integer
      }
    },
    "node.pair.list" => %{optional: %{}},
    "node.pair.approve" => %{
      required: %{
        "pairingId" => :string
      }
    },
    "node.pair.reject" => %{
      required: %{
        "pairingId" => :string
      }
    },
    "node.pair.verify" => %{
      required: %{
        "code" => :string
      }
    },
    "node.rename" => %{
      required: %{
        "nodeId" => :string,
        "name" => :string
      }
    },
    "node.list" => %{optional: %{}},
    "node.describe" => %{
      required: %{
        "nodeId" => :string
      }
    },
    "node.invoke" => %{
      required: %{
        "nodeId" => :string,
        "method" => :string
      },
      optional: %{
        "args" => :map,
        "timeoutMs" => :integer
      }
    },
    "node.invoke.result" => %{
      required: %{
        "invokeId" => :string
      },
      optional: %{
        "result" => :any,
        "error" => :string
      }
    },
    "node.event" => %{
      required: %{
        "eventType" => :string
      },
      optional: %{
        "payload" => :map
      }
    },

    # Voice/TTS methods
    "voicewake.get" => %{optional: %{}},
    "voicewake.set" => %{
      required: %{
        "enabled" => :boolean
      },
      optional: %{
        "keyword" => :string
      }
    },
    "tts.status" => %{optional: %{}},
    "tts.providers" => %{optional: %{}},
    "tts.enable" => %{
      optional: %{
        "provider" => :string
      }
    },
    "tts.disable" => %{optional: %{}},
    "tts.convert" => %{
      required: %{
        "text" => :string
      },
      optional: %{
        "provider" => :string
      }
    },
    "tts.set-provider" => %{
      required: %{
        "provider" => :string
      }
    },

    # Automation methods
    "wake" => %{
      optional: %{
        "agentId" => :string,
        "message" => :string
      }
    },
    "set-heartbeats" => %{
      required: %{
        "enabled" => :boolean
      },
      optional: %{
        "agentId" => :string,
        "intervalMs" => :integer,
        "prompt" => :string
      }
    },
    "last-heartbeat" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "talk.mode" => %{
      optional: %{
        "sessionKey" => :string,
        "mode" => :string
      }
    },

    # Config methods
    "config.get" => %{
      optional: %{
        "key" => :string
      }
    },
    "config.set" => %{
      required: %{
        "key" => :string,
        "value" => :any
      }
    },
    "config.patch" => %{
      required: %{
        "patch" => :map
      }
    },
    "config.schema" => %{optional: %{}},
    "config.reload" => %{
      optional: %{
        "sources" => :list,
        "force" => :boolean,
        "reason" => :string
      }
    },
    "secrets.status" => %{optional: %{}},
    "secrets.list" => %{
      optional: %{
        "owner" => :string
      }
    },
    "secrets.set" => %{
      required: %{
        "name" => :string,
        "value" => :string
      },
      optional: %{
        "provider" => :string,
        "expiresAt" => :integer
      }
    },
    "secrets.delete" => %{
      required: %{
        "name" => :string
      }
    },
    "secrets.exists" => %{
      required: %{
        "name" => :string
      },
      optional: %{
        "preferEnv" => :boolean,
        "envFallback" => :boolean
      }
    },

    # Usage methods
    "usage.status" => %{optional: %{}},
    "usage.cost" => %{
      optional: %{
        "startDate" => :string,
        "endDate" => :string
      }
    },

    # System methods
    "system-presence" => %{optional: %{}},
    "system-event" => %{
      required_any: [["eventType", "event_type"]],
      optional: %{
        "eventType" => :string,
        "event_type" => :string,
        "payload" => :map,
        "target" => :string
      }
    },
    "system.reload" => %{
      "type" => "object",
      "required" => ["scope"],
      "properties" => %{
        "scope" => %{"type" => "string", "enum" => ["module", "app", "extension", "all"]},
        "module" => %{"type" => "string"},
        "app" => %{"type" => "string"},
        "path" => %{"type" => "string"},
        "force" => %{"type" => "boolean"},
        "compile" => %{"type" => "boolean"},
        "apps" => %{"type" => "array"},
        "extensions" => %{"type" => "array"}
      },
      "additionalProperties" => true,
      required: %{
        "scope" => :string
      },
      optional: %{
        "module" => :string,
        "app" => :string,
        "path" => :string,
        "apps" => :list,
        "extensions" => :list,
        "force" => :boolean,
        "compile" => :boolean
      }
    },

    # Send method schema
    "send" => %{
      required: %{
        "channelId" => :string,
        "content" => :string
      },
      optional: %{
        "accountId" => :string,
        "peerId" => :string,
        "idempotencyKey" => :string
      }
    },

    # Optional capability-gated methods
    "update.run" => %{
      optional: %{
        "force" => :boolean
      }
    },
    "connect.challenge" => %{
      required: %{
        "challenge" => :string
      }
    },
    "device.pair.request" => %{
      required: %{
        "deviceType" => :string,
        "deviceName" => :string
      },
      optional: %{
        "expiresInMs" => :integer
      }
    },
    "device.pair.approve" => %{
      required: %{
        "pairingId" => :string
      }
    },
    "device.pair.reject" => %{
      required: %{
        "pairingId" => :string
      }
    },
    "wizard.start" => %{
      optional: %{
        "wizardId" => :string
      }
    },
    "wizard.step" => %{
      required: %{
        "wizardId" => :string,
        "stepId" => :string
      },
      optional: %{
        "data" => :map
      }
    },
    "wizard.cancel" => %{
      required: %{
        "wizardId" => :string
      }
    }
  }

  @event_schemas %{
    "exec.approval.requested" => %{
      required: %{
        "approvalId" => :string,
        "tool" => :string,
        "action" => :map
      },
      optional: %{
        "runId" => :string,
        "sessionKey" => :string,
        "agentId" => :string,
        "rationale" => :string,
        "requestedAtMs" => :integer,
        "expiresAtMs" => :integer
      }
    },
    "exec.approval.resolved" => %{
      required: %{
        "approvalId" => :string,
        "decision" => :string
      },
      optional: %{
        "runId" => :string,
        "sessionKey" => :string,
        "agentId" => :string,
        "tool" => :string
      }
    }
  }

  @doc """
  Get schema for a method.
  """
  @spec get(String.t()) :: map() | nil
  def get(method), do: Map.get(@schemas, method)

  @doc """
  Get schema for a server-to-client event payload.
  """
  @spec get_event(String.t()) :: map() | nil
  def get_event(event), do: Map.get(@event_schemas, event)

  @doc """
  Validate params against a method's schema.

  Returns :ok or {:error, reason}.
  """
  @spec validate(String.t(), map() | nil) :: :ok | {:error, String.t()}
  def validate(method, params) do
    case get(method) do
      nil ->
        # No schema defined, allow anything
        :ok

      schema ->
        do_validate(params || %{}, schema)
    end
  end

  @doc """
  Validate a server-to-client event payload against its event schema.

  Events without schema entries are allowed so existing untyped events remain
  backwards-compatible.
  """
  @spec validate_event(String.t(), map() | nil) :: :ok | {:error, String.t()}
  def validate_event(event, payload) do
    case get_event(event) do
      nil -> :ok
      schema -> do_validate(payload || %{}, schema)
    end
  end

  defp do_validate(params, schema) do
    required = Map.get(schema, :required, %{})
    required_any = Map.get(schema, :required_any, [])

    # Check required fields
    missing =
      required
      |> Enum.filter(fn {field, _type} -> is_nil(Map.get(params, field)) end)
      |> Enum.map(fn {field, _type} -> field end)

    missing_any =
      required_any
      |> Enum.reject(fn fields -> Enum.any?(fields, &(not is_nil(Map.get(params, &1)))) end)
      |> Enum.map(&Enum.join(&1, " or "))

    if length(missing) > 0 or length(missing_any) > 0 do
      missing_parts =
        []
        |> maybe_missing("Missing required fields", missing)
        |> maybe_missing("Missing one of", missing_any)

      {:error, Enum.join(missing_parts, "; ")}
    else
      # Validate types of provided fields
      all_fields = Map.merge(required, Map.get(schema, :optional, %{}))

      type_errors =
        params
        |> Enum.filter(fn {field, value} ->
          expected_type = Map.get(all_fields, field)
          expected_type != nil and not valid_type?(value, expected_type)
        end)
        |> Enum.map(fn {field, value} ->
          expected_type = Map.get(all_fields, field)
          "#{field}: expected #{format_type(expected_type)}, got #{typeof(value)}"
        end)

      if length(type_errors) > 0 do
        {:error, "Type errors: #{Enum.join(type_errors, "; ")}"}
      else
        :ok
      end
    end
  end

  # nil is allowed for optional fields - must be first to match before type checks
  defp valid_type?(nil, _), do: true

  defp valid_type?(value, expected_types) when is_list(expected_types) do
    Enum.any?(expected_types, &valid_type?(value, &1))
  end

  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :list), do: is_list(value)
  defp valid_type?(_, :any), do: true
  defp valid_type?(_, _), do: false

  defp maybe_missing(parts, _label, []), do: parts
  defp maybe_missing(parts, label, fields), do: parts ++ ["#{label}: #{Enum.join(fields, ", ")}"]

  defp format_type(expected_types) when is_list(expected_types) do
    expected_types
    |> Enum.map(&format_type/1)
    |> Enum.join(" or ")
  end

  defp format_type(expected_type), do: to_string(expected_type)

  defp typeof(value) when is_binary(value), do: "string"
  defp typeof(value) when is_integer(value), do: "integer"
  defp typeof(value) when is_float(value), do: "float"
  defp typeof(value) when is_boolean(value), do: "boolean"
  defp typeof(value) when is_map(value), do: "map"
  defp typeof(value) when is_list(value), do: "list"
  defp typeof(nil), do: "null"
  defp typeof(_), do: "unknown"
end
