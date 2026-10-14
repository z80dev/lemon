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
    "doctor.run" => %{optional: %{}},
    "logs.tail" => %{
      optional: %{
        "limit" => :integer,
        "level" => :string,
        "lines" => :integer,
        "filter" => :string
      }
    },

    # Channel methods
    "commands.catalog" => %{optional: %{}},
    "background.start" => %{
      required: %{"prompt" => :string},
      optional: %{
        "sessionId" => :string,
        "sessionKey" => :string,
        "cwd" => :string,
        "model" => :string,
        "thinkingLevel" => :string,
        "timeoutMs" => :integer
      }
    },
    "background.list" => %{optional: %{"status" => :string}},
    "background.status" => %{required: %{"id" => :string}, optional: %{}},
    "background.result" => %{required: %{"id" => :string}, optional: %{}},
    "background.cancel" => %{required: %{"id" => :string}, optional: %{}},
    "session.btw" => %{
      required: %{"question" => :string},
      required_any: [["sessionId", "sessionKey"]],
      optional: %{"sessionId" => :string, "sessionKey" => :string, "timeoutMs" => :integer}
    },

    # Model methods
    "models.list" => %{
      optional: %{
        "discoverOpenAI" => :boolean
      }
    },

    # User-managed profiles
    "profiles.list" => %{optional: %{}},
    "profiles.get" => %{required: %{"id" => :string}, optional: %{}},
    "profiles.create" => %{
      required: %{"id" => :string},
      optional: %{
        "name" => :string,
        "description" => :string,
        "avatar" => :string,
        "model" => :string,
        "systemPrompt" => :string,
        "node" => :string
      }
    },
    "profiles.clone" => %{
      required: %{"sourceId" => :string, "id" => :string},
      optional: %{
        "name" => :string,
        "description" => :string,
        "avatar" => :string,
        "model" => :string,
        "systemPrompt" => :string,
        "node" => :string
      }
    },
    "profiles.rename" => %{required: %{"id" => :string, "name" => :string}, optional: %{}},
    "profiles.export" => %{
      required: %{"id" => :string, "path" => :string},
      optional: %{"force" => :boolean}
    },
    "profiles.delete" => %{
      required: %{"id" => :string, "confirm" => :string},
      optional: %{}
    },
    "profiles.roster" => %{optional: %{}},
    "profile.chat" => %{
      required: %{"id" => :string, "prompt" => :string},
      optional: %{
        "images" => :list,
        "model" => :string,
        "queueMode" => :string
      }
    },

    # Agent methods
    "agents.list" => %{optional: %{}},
    "agent" => %{
      required: %{
        "prompt" => :string
      },
      optional: %{
        "sessionKey" => :string,
        "agentId" => :string,
        "queueMode" => :string,
        "model" => :string
      }
    },
    "agent.wait" => %{
      optional: %{
        "runId" => :string,
        "timeoutMs" => :integer
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
    "goal.clear" => %{
      required: %{
        "sessionKey" => :string
      }
    },

    # Skill methods
    "skills.hermes.catalog" => %{
      optional: %{
        "cwd" => :string,
        "query" => :string,
        "category" => :string,
        "collection" => :string,
        "details" => :boolean
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
    "skills.list" => %{
      optional: %{
        "cwd" => :string
      }
    },
    "skills.enable" => %{
      required: %{
        "skillKey" => :string
      },
      optional: %{
        "cwd" => :string
      }
    },
    "skills.disable" => %{
      required: %{
        "skillKey" => :string
      },
      optional: %{
        "cwd" => :string
      }
    },
    "mcp.servers.list" => %{},
    "mcp.servers.refresh" => %{},
    "blueprints.list" => %{},
    "blueprints.inspect" => %{
      required: %{
        "bundleId" => :string
      }
    },
    "blueprints.validate" => %{
      required: %{
        "bundleId" => :string
      }
    },
    "blueprints.preview" => %{
      required: %{
        "bundleId" => :string,
        "profileId" => :string
      }
    },
    "blueprints.activate" => %{
      required: %{
        "bundleId" => :string,
        "profileId" => :string,
        "confirmationDigest" => :string
      }
    },

    # Session methods
    "sessions.list" => %{
      optional: %{
        "limit" => :integer,
        "offset" => :integer,
        "agentId" => :string,
        "query" => :string,
        "pinned" => :boolean,
        "archived" => :boolean
      }
    },
    "sessions.get" => %{required: %{"sessionKey" => :string}, optional: %{}},
    "sessions.history" => %{
      required: %{"sessionKey" => :string},
      optional: %{"limit" => :integer}
    },
    "sessions.create" => %{
      required: %{"sessionKey" => :string, "cwd" => :string},
      optional: %{}
    },
    "sessions.plan" => %{
      required: %{"sessionKey" => :string, "cwd" => :string, "action" => :string},
      optional: %{}
    },
    "sessions.context" => %{
      required: %{"sessionKey" => :string, "cwd" => :string}
    },
    "sessions.changes" => %{
      required: %{"sessionKey" => :string, "cwd" => :string},
      optional: %{"path" => :string}
    },
    "sessions.tree" => %{
      required: %{"sessionKey" => :string, "cwd" => :string},
      optional: %{"limit" => :integer, "offset" => :integer}
    },
    "sessions.rewind" => %{
      required: %{"sessionKey" => :string, "cwd" => :string, "entryId" => :string},
      optional: %{
        "restoreFiles" => :boolean,
        "allowPartialRestore" => :boolean,
        "dryRun" => :boolean,
        "confirmationToken" => :string
      }
    },
    "sessions.fork" => %{
      required: %{"sessionKey" => :string, "cwd" => :string}
    },
    "sessions.stats" => %{
      optional: %{
        "agentId" => :string,
        "query" => :string,
        "pinned" => :boolean,
        "archived" => :boolean,
        "groupLimit" => :integer
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
    "sessions.metadata.patch" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "title" => :any,
        "pinned" => :boolean,
        "archived" => :boolean
      }
    },
    "sessions.export" => %{
      required: %{
        "sessionKey" => :string
      },
      optional: %{
        "format" => :string
      }
    },
    "sessions.prune" => %{
      required: %{
        "olderThanMs" => :integer
      },
      optional: %{
        "archivedOnly" => :boolean,
        "includePinned" => :boolean,
        "dryRun" => :boolean,
        "confirmToken" => :string
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
        "cwd" => :string,
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
        "cwd" => :string,
        "images" => :list,
        "queueMode" => :string
      }
    },
    "chat.abort" => %{
      optional: %{
        "sessionKey" => :string,
        "runId" => :string
      }
    },

    # Execution/approval methods
    "exec.approvals.get" => %{
      optional: %{
        "agentId" => :string
      }
    },
    "exec.approval.resolve" => %{
      required: %{
        "approvalId" => :string,
        "decision" => :string
      }
    },

    # Node methods
    "node.pair.invite" => %{
      required: %{"nodeName" => :string},
      optional: %{"purpose" => :string, "labels" => :map, "expiresInMs" => :integer, "nodeId" => :string}
    },
    "node.pair.invite.revoke" => %{required: %{"inviteId" => :string}},
    "node.capabilities.get" => %{required: %{"nodeId" => :string}},
    "node.runtime.features" => %{required: %{"nodeId" => :string}},
    "node.host.info" => %{required: %{"nodeId" => :string}},
    "node.fs.list" => %{required: %{"nodeId" => :string, "path" => :string}, optional: %{"showHidden" => :boolean}},
    "node.fs.stat" => %{required: %{"nodeId" => :string, "path" => :string}},
    "node.fs.read" => %{required: %{"nodeId" => :string, "path" => :string}, optional: %{"offset" => :integer, "length" => :integer}},
    "node.fs.write" => %{required: %{"nodeId" => :string, "path" => :string, "dataBase64" => :string}, optional: %{"offset" => :integer, "truncate" => :boolean, "mkdirs" => :boolean, "expectedModifiedAtMs" => :integer}},
    "node.fs.mkdir" => %{required: %{"nodeId" => :string, "path" => :string}},
    "node.fs.move" => %{required: %{"nodeId" => :string, "path" => :string, "destination" => :string, "expectedModifiedAtMs" => :integer}, optional: %{"overwrite" => :boolean}},
    "node.fs.delete.preview" => %{required: %{"nodeId" => :string, "path" => :string}, optional: %{"recursive" => :boolean}},
    "node.fs.delete" => %{required: %{"nodeId" => :string, "path" => :string, "confirm" => :string, "confirmationToken" => :string}},
    "node.secrets.set" => %{required: %{"nodeId" => :string, "name" => :string, "value" => :string}, optional: %{"operationId" => :string}},
    "node.secrets.list" => %{required: %{"nodeId" => :string}},
    "node.secrets.delete" => %{required: %{"nodeId" => :string, "name" => :string}},
    "node.secrets.receipt" => %{required: %{"nodeId" => :string, "operationId" => :string}},
    "node.process.run" => %{
      required: %{
        "nodeId" => :string,
        "processId" => :string,
        "cwd" => :string,
        "argv" => :list,
        "stdinBase64" => :string,
        "timeoutMs" => :integer,
        "maxOutputBytes" => :integer
      }
    },
    "node.process.get" => %{required: %{"nodeId" => :string, "processId" => :string}},
    "node.process.cancel" => %{required: %{"nodeId" => :string, "processId" => :string}},
    "node.shell.open" => %{required: %{"nodeId" => :string}, optional: %{"cwd" => :string, "cols" => :integer, "rows" => :integer}},
    "node.shell.input" => %{required: %{"shellId" => :string, "dataBase64" => :string}},
    "node.shell.resize" => %{required: %{"shellId" => :string, "cols" => :integer, "rows" => :integer}},
    "node.shell.close" => %{required: %{"shellId" => :string}},
    "node.shell.event" => %{required: %{"invokeId" => :string, "payload" => :map}},
    "node.pair.request" => %{
      required: %{
        "nodeType" => :string,
        "nodeName" => :string
      },
      optional: %{
        "expiresInMs" => :integer,
        "capabilities" => :map,
        "nodeId" => :string,
        "recoveryToken" => :string,
        "repair" => :boolean,
        "inviteCode" => :string
      }
    },
    "node.pair.approve" => %{
      required: %{
        "pairingId" => :string
      }
    },
    "nodes.list" => %{optional: %{"name" => :string, "nodeId" => :string}},
    "nodes.revoke" => %{
      required: %{
        "nodeId" => :string,
        "confirmName" => :string
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
    "node.invoke.control.result" => %{
      required: %{
        "controlId" => :string,
        "invokeId" => :string,
        "runId" => :string,
        "accepted" => :boolean
      },
      optional: %{
        "reason" => :string
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

    # Usage methods
    "usage.status" => %{optional: %{}},
    "usage.cost" => %{
      optional: %{
        "startDate" => :string,
        "endDate" => :string
      }
    },

    # Node connect challenge
    "connect.challenge" => %{
      required: %{
        "challenge" => :string
      }
    },

    # omp delegate sessions
    "omp.status" => %{optional: %{}},
    "omp.sessions.list" => %{optional: %{"includeEnded" => :boolean, "limit" => :integer}},
    "omp.sessions.get" => %{required: %{"id" => :string}},
    "omp.sessions.discover" => %{required: %{"cwd" => :string}, optional: %{"limit" => :integer}},
    "omp.sessions.start" => %{
      required: %{"prompt" => :string, "cwd" => :string},
      optional: %{"model" => :string, "thinking" => :string}
    },
    "omp.sessions.resume" => %{
      required: %{"ompSessionId" => :string, "cwd" => :string},
      optional: %{"prompt" => :string, "model" => :string, "thinking" => :string}
    },
    "omp.sessions.send" => %{
      required: %{"id" => :string, "message" => :string},
      optional: %{"mode" => :string}
    },
    "omp.sessions.cancel" => %{required: %{"id" => :string}},
    "omp.sessions.close" => %{required: %{"id" => :string}}
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
    },
    "omp.session" => %{
      required: %{
        "reason" => :string,
        "session" => :map
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

    if missing != [] or missing_any != [] do
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

      if type_errors != [] do
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
