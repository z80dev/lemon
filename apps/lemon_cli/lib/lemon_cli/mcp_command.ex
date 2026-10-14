defmodule LemonCli.McpCommand do
  @moduledoc "Mix-free named MCP configuration commands for source and packaged launchers."

  alias LemonSkills.McpConfig
  alias LemonSkills.McpSession

  @common [global: :boolean, cwd: :string, json: :boolean]
  @add [
    stdio: :string,
    http: :string,
    env: :keep,
    header: :keep,
    approval: :string,
    tool_approval: :keep,
    replace: :boolean
  ]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run([action | args])
      when action in ["add", "list", "remove", "test", "enable", "disable"] do
    {flags, command_args} = split_command_args(args)

    switches =
      case action do
        "add" -> @common ++ @add
        "list" -> @common ++ [all: :boolean]
        _ -> @common
      end

    {opts, positional, invalid} = OptionParser.parse(flags, strict: switches)

    with true <- invalid == [],
         true <- action == "add" or command_args == nil,
         {:ok, request} <- request(action, positional, opts, command_args) do
      result = execute(action, request, opts)
      render(result, opts[:json] == true)
    else
      _ -> usage_error()
    end
  rescue
    _ -> render({:error, :operation_failed}, "--json" in args)
  catch
    _, _ -> render({:error, :operation_failed}, "--json" in args)
  end

  def run(_), do: usage_error()

  defp split_command_args(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {flags, []} -> {flags, nil}
      {flags, ["--" | command_args]} -> {flags, command_args}
    end
  end

  defp request("list", [], _opts, nil), do: {:ok, nil}

  defp request(action, [name], _opts, nil) when action in ["remove", "test"] do
    if McpConfig.valid_name?(name), do: {:ok, name}, else: :error
  end

  defp request(action, [name], _opts, nil) when action in ["enable", "disable"] do
    if McpConfig.valid_reference?(name), do: {:ok, name}, else: :error
  end

  defp request("add", [name], opts, command_args) do
    with {:ok, env} <- pairs(Keyword.get_values(opts, :env)),
         {:ok, headers} <- pairs(Keyword.get_values(opts, :header)),
         {:ok, tools} <- pairs(Keyword.get_values(opts, :tool_approval)),
         {:ok, transport} <- transport(opts, command_args, env, headers) do
      entry =
        transport
        |> Map.put("name", name)
        |> Map.put("approval", Keyword.get(opts, :approval, "always"))
        |> maybe_put("tool_approvals", tools)

      if McpConfig.valid_entry?(entry), do: {:ok, entry}, else: :error
    end
  end

  defp request(_, _, _, _), do: :error

  defp transport(opts, args, env, headers) do
    case {opts[:stdio], opts[:http]} do
      {command, nil} when is_binary(command) and map_size(headers) == 0 ->
        {:ok,
         %{"type" => "stdio", "command" => command, "args" => args || []}
         |> maybe_put("env", env)}

      {nil, url} when is_binary(url) and is_nil(args) and map_size(env) == 0 ->
        {:ok, %{"type" => "http", "url" => url} |> maybe_put("headers", headers)}

      _ ->
        :error
    end
  end

  defp pairs(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, pairs} ->
      case String.split(value, "=", parts: 2) do
        [key, value] when key != "" ->
          if Map.has_key?(pairs, key),
            do: {:halt, :error},
            else: {:cont, {:ok, Map.put(pairs, key, value)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp maybe_put(map, _key, value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp execute("add", entry, opts) do
    with :ok <- McpConfig.add(entry, opts), do: {:ok, %{"status" => "saved"}}
  end

  defp execute("remove", name, opts) do
    with :ok <- McpConfig.remove(name, opts), do: {:ok, %{"status" => "removed"}}
  end

  defp execute(action, name, opts) when action in ["enable", "disable"] do
    with :ok <- McpConfig.set_enabled(name, action == "enable", opts),
         do: {:ok, %{"status" => action <> "d"}}
  end

  defp execute("list", _, opts) do
    with {:ok, servers} <- McpConfig.list(opts) do
      if opts[:all], do: {:ok, %{"effective" => servers}}, else: {:ok, %{"servers" => servers}}
    end
  end

  defp execute("test", name, opts) do
    with {:ok, entry} <- McpConfig.fetch(name, opts) do
      LemonCli.Onboarding.LogSilencer.with_quiet_logs(true, fn -> test_connection(entry, opts) end)
    end
  end

  defp test_connection(entry, opts) do
    id = "mcp-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case Application.ensure_all_started(:lemon_skills) do
      {:ok, _} ->
        try do
          case McpSession.open(id, Keyword.get(opts, :cwd, File.cwd!()), [entry], self()) do
            :ok ->
              tools = McpSession.tools(id)
              {:ok, %{"status" => "connected", "tool_count" => length(tools)}}

            _ ->
              {:error, :connection_failed}
          end
        after
          McpSession.close(id)
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp render({:ok, payload}, true) do
    IO.puts(Jason.encode!(payload))
    0
  end

  defp render({:ok, %{"servers" => servers}}, false) do
    if servers == [] do
      IO.puts("No MCP servers configured in this scope.")
    else
      Enum.each(servers, fn server ->
        IO.puts(
          "#{server["name"] || "(unnamed)"}\t#{server["type"]}\tapproval=#{server["approval"]}\ttool overrides=#{server["tool_approval_count"]}\tenv=#{server["environment_count"]}\theaders=#{server["header_count"]}"
        )
      end)
    end

    0
  end

  defp render({:ok, %{"effective" => servers}}, false) do
    if servers == [] do
      IO.puts("No MCP servers configured or discovered for this scope.")
    else
      Enum.each(servers, fn server ->
        state =
          cond do
            server["enabled"] -> "enabled"
            server["override"] == "disabled" -> "disabled (override)"
            true -> "disabled (source)"
          end

        IO.puts(
          "#{server["name"] || "(unnamed)"}\t#{server["type"]}\tsource=#{server["provider"]}:#{server["scope"]}\t#{state}\tapproval=#{server["approval"]}\ttool overrides=#{server["tool_approval_count"]}\tenv=#{server["environment_count"]}\theaders=#{server["header_count"]}"
        )
      end)
    end

    0
  end

  defp render({:ok, %{"status" => "connected", "tool_count" => count}}, false) do
    IO.puts("MCP connected: #{count} tool(s) discovered; no tools executed.")
    0
  end

  defp render({:ok, %{"status" => status}}, false) when status in ["enabled", "disabled"] do
    IO.puts("MCP server #{status} in this scope. New sessions read the updated configuration.")
    0
  end

  defp render({:ok, %{"status" => status}}, false) do
    IO.puts("MCP configuration #{status}. New sessions read the updated configuration.")
    0
  end

  defp render({:error, reason}, json?) do
    message = error_message(reason)

    if json?,
      do: IO.puts(:stderr, Jason.encode!(%{"error" => "mcp_failed", "message" => message})),
      else: IO.puts(:stderr, "MCP failed: " <> message)

    1
  end

  defp error_message(:duplicate_name),
    do: "The name already exists or is ambiguous; use --replace only for a unique entry."

  defp error_message(:not_found), do: "No server has that exact name in the selected scope."

  defp error_message(:invalid_config),
    do: "The selected MCP file is invalid; no changes were made."

  defp error_message(:busy),
    do: "Another writer holds the MCP file lock. Inspect an abandoned lock before removing it."

  defp error_message(:changed),
    do: "The MCP file changed during this operation; no changes were written."

  defp error_message(:connection_failed),
    do: "The MCP server could not connect and discover tools."

  defp error_message(:read_failed), do: "The MCP configuration could not be read."
  defp error_message(:write_failed), do: "The MCP configuration could not be saved."
  defp error_message(:unavailable), do: "The MCP runtime is unavailable."
  defp error_message(_), do: "The MCP operation failed."

  defp usage_error do
    IO.puts(:stderr, "Invalid MCP arguments. Run `lemon mcp --help` for usage.")
    2
  end
end
