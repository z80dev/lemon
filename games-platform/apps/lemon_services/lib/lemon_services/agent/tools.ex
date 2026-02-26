defmodule LemonServices.Agent.Tools do
  @moduledoc """
  Agent tools for service management.

  These tools allow agents to:
  - Start, stop, and restart services
  - Query service status and logs
  - Define new services
  - Stream service output

  ## Available Tools

  - `service_start` - Start a service
  - `service_stop` - Stop a service
  - `service_restart` - Restart a service
  - `service_status` - Get service status
  - `service_logs` - Get service logs
  - `service_list` - List all services
  - `service_attach` - Subscribe to service logs
  - `service_define` - Define a new service
  """

  alias LemonServices.Service.Definition

  @doc """
  Schema for service_start tool.
  """
  def service_start_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service to start"
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_start tool.
  """
  def service_start_execute(%{"service_id" => service_id}, _context) do
    service_id = String.to_atom(service_id)

    case LemonServices.start_service(service_id) do
      {:ok, _pid} ->
        {:ok, %{status: "started", service_id: service_id}}

      {:error, :definition_not_found} ->
        {:error, "Service definition not found: #{service_id}"}

      {:error, :already_running} ->
        {:ok, %{status: "already_running", service_id: service_id}}

      {:error, reason} ->
        {:error, "Failed to start service: #{inspect(reason)}"}
    end
  end

  @doc """
  Schema for service_stop tool.
  """
  def service_stop_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service to stop"
        },
        timeout: %{
          type: "integer",
          description: "Graceful shutdown timeout in milliseconds",
          default: 5000
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_stop tool.
  """
  def service_stop_execute(%{"service_id" => service_id} = params, _context) do
    service_id = String.to_atom(service_id)
    timeout = Map.get(params, "timeout", 5000)

    case LemonServices.stop_service(service_id, timeout: timeout) do
      :ok ->
        {:ok, %{status: "stopped", service_id: service_id}}

      {:error, :not_running} ->
        {:ok, %{status: "not_running", service_id: service_id}}
    end
  end

  @doc """
  Schema for service_restart tool.
  """
  def service_restart_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service to restart"
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_restart tool.
  """
  def service_restart_execute(%{"service_id" => service_id}, _context) do
    service_id = String.to_atom(service_id)

    case LemonServices.restart_service(service_id) do
      {:ok, _pid} ->
        {:ok, %{status: "restarted", service_id: service_id}}

      {:error, reason} ->
        {:error, "Failed to restart service: #{inspect(reason)}"}
    end
  end

  @doc """
  Schema for service_status tool.
  """
  def service_status_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service to check"
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_status tool.
  """
  def service_status_execute(%{"service_id" => service_id}, _context) do
    service_id = String.to_atom(service_id)

    case LemonServices.get_service(service_id) do
      {:ok, state} ->
        {:ok, %{
          service_id: service_id,
          name: state.definition.name,
          status: state.status,
          health: state.health_status,
          pid: state.pid && :erlang.pid_to_list(state.pid),
          started_at: state.started_at && DateTime.to_iso8601(state.started_at),
          restart_count: state.restart_count,
          last_exit_code: state.last_exit_code,
          tags: state.definition.tags
        }}

      {:error, :not_running} ->
        # Check if definition exists
        case LemonServices.get_definition(service_id) do
          {:ok, definition} ->
            {:ok, %{
              service_id: service_id,
              name: definition.name,
              status: :stopped,
              health: :unknown,
              tags: definition.tags,
              note: "Service is defined but not running"
            }}

          {:error, :not_found} ->
            {:error, "Service not found: #{service_id}"}
        end
    end
  end

  @doc """
  Schema for service_logs tool.
  """
  def service_logs_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service"
        },
        lines: %{
          type: "integer",
          description: "Number of lines to retrieve",
          default: 50
        },
        stream: %{
          type: "string",
          description: "Filter by stream (stdout, stderr, or all)",
          default: "all",
          enum: ["stdout", "stderr", "all"]
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_logs tool.
  """
  def service_logs_execute(%{"service_id" => service_id} = params, _context) do
    service_id = String.to_atom(service_id)
    lines = Map.get(params, "lines", 50)
    stream = Map.get(params, "stream", "all")

    logs = LemonServices.get_logs(service_id, lines)

    # Filter by stream if requested
    logs =
      if stream != "all" do
        stream_atom = String.to_atom(stream)
        Enum.filter(logs, &(&1.stream == stream_atom))
      else
        logs
      end

    formatted_logs =
      Enum.map(logs, fn log ->
        %{
          timestamp: log.timestamp && DateTime.to_iso8601(log.timestamp),
          stream: log.stream,
          data: log.data
        }
      end)

    {:ok, %{
      service_id: service_id,
      lines: length(formatted_logs),
      logs: formatted_logs
    }}
  end

  @doc """
  Schema for service_list tool.
  """
  def service_list_schema do
    %{
      type: "object",
      properties: %{
        tag: %{
          type: "string",
          description: "Filter by tag"
        },
        status: %{
          type: "string",
          description: "Filter by status",
          enum: ["running", "stopped", "all"]
        }
      }
    }
  end

  @doc """
  Execute service_list tool.
  """
  def service_list_execute(params, _context) do
    tag = Map.get(params, "tag")
    status_filter = Map.get(params, "status", "all")

    services =
      if tag do
        tag_atom = String.to_atom(tag)
        LemonServices.list_services_by_tag(tag_atom)
      else
        LemonServices.list_services()
      end

    # Also include stopped services that have definitions
    definitions = LemonServices.list_definitions()
    running_ids = Enum.map(services, & &1.definition.id)

    stopped_services =
      definitions
      |> Enum.reject(&(&1.id in running_ids))
      |> Enum.map(fn def ->
        %{
          id: def.id,
          name: def.name,
          status: :stopped,
          health: :unknown,
          tags: def.tags
        }
      end)

    all_services =
      services
      |> Enum.map(fn state ->
        %{
          id: state.definition.id,
          name: state.definition.name,
          status: state.status,
          health: state.health_status,
          tags: state.definition.tags
        }
      end)
      |> Enum.concat(stopped_services)

    # Apply status filter
    filtered =
      case status_filter do
        "running" -> Enum.filter(all_services, &(&1.status in [:running, :unhealthy, :starting]))
        "stopped" -> Enum.filter(all_services, &(&1.status in [:stopped, :crashed, :pending]))
        _ -> all_services
      end

    {:ok, %{
      count: length(filtered),
      services: filtered
    }}
  end

  @doc """
  Schema for service_attach tool.

  This subscribes the session to service logs. The session will receive
  log messages until detached.
  """
  def service_attach_schema do
    %{
      type: "object",
      properties: %{
        service_id: %{
          type: "string",
          description: "The ID of the service to attach to"
        },
        detach: %{
          type: "boolean",
          description: "If true, unsubscribe instead of subscribe",
          default: false
        }
      },
      required: ["service_id"]
    }
  end

  @doc """
  Execute service_attach tool.
  """
  def service_attach_execute(%{"service_id" => service_id} = params, context) do
    service_id = String.to_atom(service_id)
    detach = Map.get(params, "detach", false)

    # Get the session PID from context
    _session_pid = Map.get(context, :session_pid, self())

    if detach do
      LemonServices.unsubscribe_from_logs(service_id)
      {:ok, %{status: "detached", service_id: service_id}}
    else
      case LemonServices.subscribe_to_logs(service_id) do
        :ok ->
          # Also subscribe to events
          LemonServices.subscribe_to_events(service_id)

          {:ok, %{
            status: "attached",
            service_id: service_id,
            note: "You will now receive log messages. Use detach: true to stop."
          }}

        {:error, :not_running} ->
          {:error, "Service is not running: #{service_id}"}
      end
    end
  end

  @doc """
  Schema for service_define tool.
  """
  def service_define_schema do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "Unique identifier for the service (e.g., 'dev_server')"
        },
        name: %{
          type: "string",
          description: "Human-readable name for the service"
        },
        command: %{
          type: "string",
          description: "Shell command to run"
        },
        command_args: %{
          type: "array",
          description: "Command arguments as array (alternative to command string)",
          items: %{type: "string"}
        },
        working_dir: %{
          type: "string",
          description: "Working directory for the service"
        },
        env: %{
          type: "object",
          description: "Environment variables",
          additionalProperties: %{type: "string"}
        },
        auto_start: %{
          type: "boolean",
          description: "Start automatically on boot",
          default: false
        },
        restart_policy: %{
          type: "string",
          description: "Restart policy: permanent, transient, or temporary",
          default: "transient",
          enum: ["permanent", "transient", "temporary"]
        },
        tags: %{
          type: "array",
          description: "Tags for categorizing services",
          items: %{type: "string"},
          default: []
        },
        persistent: %{
          type: "boolean",
          description: "Persist this definition to disk",
          default: false
        }
      },
      required: ["id", "name", "command"]
    }
  end

  @doc """
  Execute service_define tool.
  """
  def service_define_execute(params, context) do
    id = String.to_atom(params["id"])
    name = params["name"]

    # Build command
    command =
      if args = params["command_args"] do
        {:shell, args}
      else
        {:shell, params["command"]}
      end

    # Parse options
    opts = [
      id: id,
      name: name,
      command: command,
      working_dir: Map.get(params, "working_dir"),
      env: Map.get(params, "env", %{}),
      auto_start: Map.get(params, "auto_start", false),
      restart_policy: String.to_atom(Map.get(params, "restart_policy", "transient")),
      tags: Enum.map(Map.get(params, "tags", []), &String.to_atom/1),
      persistent: Map.get(params, "persistent", false),
      created_by: Map.get(context, :session_id, "unknown")
    ]

    with {:ok, definition} <- Definition.new(opts),
         :ok <- LemonServices.register_definition(definition),
         :ok <- LemonServices.Config.save_definition(definition) do
      {:ok, %{
        status: "defined",
        service_id: id,
        name: name,
        persistent: definition.persistent
      }}
    else
      {:error, reason} ->
        {:error, "Failed to define service: #{reason}"}
    end
  end

  # ============================================================================
  # Tool Registration Helper
  # ============================================================================

  @doc """
  Returns all tool definitions for registration with the agent system.

  Returns a list of {name, schema, execute_fn} tuples.
  """
  def all_tools do
    [
      {"service_start", &service_start_schema/0, &service_start_execute/2},
      {"service_stop", &service_stop_schema/0, &service_stop_execute/2},
      {"service_restart", &service_restart_schema/0, &service_restart_execute/2},
      {"service_status", &service_status_schema/0, &service_status_execute/2},
      {"service_logs", &service_logs_schema/0, &service_logs_execute/2},
      {"service_list", &service_list_schema/0, &service_list_execute/2},
      {"service_attach", &service_attach_schema/0, &service_attach_execute/2},
      {"service_define", &service_define_schema/0, &service_define_execute/2}
    ]
  end
end
