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
        "lines" => :integer,
        "filter" => :string
      }
    },

    # Channel methods
    "channels.status" => %{optional: %{}},
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
        "engineId" => :string
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

    # Cron methods
    "cron.list" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "cron.status" => %{optional: %{}},
    "cron.add" => %{
      required: %{
        "name" => :string,
        "schedule" => :string,
        "agentId" => :string,
        "sessionKey" => :string,
        "prompt" => :string
      },
      optional: %{
        "enabled" => :boolean,
        "timezone" => :string,
        "jitterSec" => :integer,
        "timeoutMs" => :integer,
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
        "timezone" => :string,
        "jitterSec" => :integer,
        "timeoutMs" => :integer
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
        "limit" => :integer
      }
    },

    # Chat methods
    "chat.history" => %{
      optional: %{
        "sessionKey" => :string,
        "limit" => :integer
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
      required: %{
        "eventType" => :string
      },
      optional: %{
        "payload" => :map,
        "target" => :string
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

  @doc """
  Get schema for a method.
  """
  @spec get(String.t()) :: map() | nil
  def get(method), do: Map.get(@schemas, method)

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

  defp do_validate(params, schema) do
    required = Map.get(schema, :required, %{})

    # Check required fields
    missing =
      required
      |> Enum.filter(fn {field, _type} -> is_nil(Map.get(params, field)) end)
      |> Enum.map(fn {field, _type} -> field end)

    if length(missing) > 0 do
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
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
          "#{field}: expected #{expected_type}, got #{typeof(value)}"
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
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :list), do: is_list(value)
  defp valid_type?(_, :any), do: true
  defp valid_type?(_, _), do: false

  defp typeof(value) when is_binary(value), do: "string"
  defp typeof(value) when is_integer(value), do: "integer"
  defp typeof(value) when is_float(value), do: "float"
  defp typeof(value) when is_boolean(value), do: "boolean"
  defp typeof(value) when is_map(value), do: "map"
  defp typeof(value) when is_list(value), do: "list"
  defp typeof(nil), do: "null"
  defp typeof(_), do: "unknown"
end
