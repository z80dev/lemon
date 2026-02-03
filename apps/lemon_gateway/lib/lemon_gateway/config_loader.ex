defmodule LemonGateway.ConfigLoader do
  @moduledoc """
  Loads configuration from TOML file with fallback to Application env.

  The TOML file should be at the path specified in `:lemon_gateway, :config_path`
  (defaults to `~/.lemon/gateway.toml`).

  If the file doesn't exist, falls back to Application env config.
  """

  alias LemonGateway.{Binding, Project}

  @default_path "~/.lemon/gateway.toml"

  @doc """
  Loads configuration from TOML file or Application env.

  Returns a map with:
  - Gateway settings (max_concurrent_runs, default_engine, etc.)
  - `:projects` - map of project_id => Project struct
  - `:bindings` - list of Binding structs
  """
  @spec load() :: map()
  def load do
    config_path = Application.get_env(:lemon_gateway, :config_path, @default_path)
    expanded_path = Path.expand(config_path)

    if File.exists?(expanded_path) do
      load_from_toml(expanded_path)
    else
      load_from_app_env()
    end
  end

  defp load_from_toml(path) do
    case Toml.decode_file(path) do
      {:ok, toml} ->
        parse_toml(toml)

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to parse TOML config at #{path}: #{inspect(reason)}, falling back to Application env")
        load_from_app_env()
    end
  end

  defp parse_toml(toml) do
    gateway = toml["gateway"] || %{}

    # Parse projects
    projects_raw = toml["projects"] || %{}

    projects =
      for {name, config} <- projects_raw, into: %{} do
        project = %Project{
          id: name,
          root: config["root"],
          default_engine: config["default_engine"]
        }

        validate_project_root(project)
        {name, project}
      end

    # Parse bindings
    bindings_raw = toml["bindings"] || []

    bindings =
      Enum.map(bindings_raw, fn b ->
        %Binding{
          transport: parse_transport(b["transport"]),
          chat_id: b["chat_id"],
          topic_id: b["topic_id"],
          project: b["project"],
          default_engine: b["default_engine"],
          queue_mode: parse_queue_mode(b["queue_mode"])
        }
      end)

    # Parse queue config
    queue_config = toml["queue"] || %{}

    queue = %{
      mode: parse_queue_mode(queue_config["mode"]),
      cap: queue_config["cap"],
      drop: parse_drop_policy(queue_config["drop"])
    }

    # Parse telegram config
    telegram_config = toml["telegram"] || %{}

    telegram = %{
      bot_token: telegram_config["bot_token"],
      allowed_chat_ids: telegram_config["allowed_chat_ids"],
      poll_interval_ms: telegram_config["poll_interval_ms"],
      edit_throttle_ms: telegram_config["edit_throttle_ms"]
    }

    # Parse engines config
    engines_raw = toml["engines"] || %{}

    engines =
      for {name, config} <- engines_raw, into: %{} do
        engine = %{
          cli_path: config["cli_path"],
          enabled: config["enabled"]
        }

        {String.to_atom(name), engine}
      end

    # Merge gateway settings with projects and bindings
    gateway
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.put(:projects, projects)
    |> Map.put(:bindings, bindings)
    |> Map.put(:queue, queue)
    |> Map.put(:telegram, telegram)
    |> Map.put(:engines, engines)
  end

  defp load_from_app_env do
    config = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})
    config_map = if is_list(config), do: Map.new(config), else: config

    # Parse projects from Application env
    projects_raw = Map.get(config_map, :projects, %{})

    projects =
      for {name, config} <- projects_raw, into: %{} do
        project = %Project{
          id: to_string(name),
          root: config[:root] || config["root"],
          default_engine: config[:default_engine] || config["default_engine"]
        }

        {to_string(name), project}
      end

    # Parse bindings from Application env
    bindings_raw = Map.get(config_map, :bindings, [])

    bindings =
      Enum.map(bindings_raw, fn b ->
        %Binding{
          transport: b[:transport] || parse_transport(b["transport"]),
          chat_id: b[:chat_id] || b["chat_id"],
          topic_id: b[:topic_id] || b["topic_id"],
          project: b[:project] || b["project"],
          default_engine: b[:default_engine] || b["default_engine"],
          queue_mode: b[:queue_mode] || parse_queue_mode(b["queue_mode"])
        }
      end)

    config_map
    |> Map.put(:projects, projects)
    |> Map.put(:bindings, bindings)
  end

  defp parse_transport(nil), do: nil
  defp parse_transport("telegram"), do: :telegram
  defp parse_transport(:telegram), do: :telegram
  defp parse_transport(other) when is_binary(other), do: String.to_atom(other)
  defp parse_transport(other) when is_atom(other), do: other

  defp parse_queue_mode(nil), do: nil
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode

  defp parse_drop_policy(nil), do: nil
  defp parse_drop_policy("oldest"), do: :oldest
  defp parse_drop_policy("newest"), do: :newest
  defp parse_drop_policy(policy) when is_atom(policy), do: policy

  defp validate_project_root(%Project{id: id, root: root}) when is_binary(root) do
    expanded = Path.expand(root)

    unless File.dir?(expanded) do
      require Logger
      Logger.warning("Project '#{id}' root directory does not exist: #{expanded}")
    end
  end

  defp validate_project_root(_), do: :ok
end
