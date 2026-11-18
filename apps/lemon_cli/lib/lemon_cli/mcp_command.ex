defmodule LemonCli.McpCommand do
  @moduledoc "Mix-free named MCP configuration commands for source and packaged launchers."

  alias LemonSkills.McpConfig
  alias LemonSkills.McpDiscovery
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
      when action in ["add", "list", "remove", "test", "enable", "disable", "trust", "untrust"] do
    {flags, command_args} = split_command_args(args)

    switches =
      case action do
        "add" -> @common ++ @add
        "list" -> @common ++ [all: :boolean]
        "trust" -> [cwd: :string, json: :boolean, digest: :string]
        "untrust" -> [cwd: :string, json: :boolean]
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
  defp request(action, [], _opts, nil) when action in ["trust", "untrust"], do: {:ok, nil}

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
      cond do
        opts[:all] != true ->
          {:ok, %{"servers" => servers}}

        opts[:global] ->
          {:ok, %{"effective" => servers}}

        true ->
          trust = project_trust(Keyword.get(opts, :cwd, File.cwd!()), false)
          {:ok, %{"effective" => servers, "project_trust" => trust}}
      end
    end
  end

  defp execute("trust", _, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case opts[:digest] do
      nil ->
        {:ok, %{"project_trust" => project_trust(cwd, true)}}

      digest ->
        with :ok <- McpConfig.trust_project(cwd, digest), do: {:ok, %{"status" => "trusted"}}
    end
  end

  defp execute("untrust", _, opts) do
    with :ok <- McpConfig.revoke_project_trust(Keyword.get(opts, :cwd, File.cwd!())),
         do: {:ok, %{"status" => "untrusted"}}
  end

  defp execute("test", name, opts) do
    with {:ok, entry, provenance} <- McpConfig.fetch(name, opts) do
      LemonCli.Onboarding.LogSilencer.with_quiet_logs(true, fn ->
        test_connection(entry, provenance, opts)
      end)
    end
  end

  # `list --all` stays a redacted inventory (counts only); the command and URL
  # previews are shown by `trust`, the review surface.
  defp project_trust(cwd, previews?) do
    status = McpDiscovery.project_status(cwd)

    summary = %{
      "project" => status.project,
      "label" => status.label,
      "cwd_arg" => status.cwd_arg,
      "trust" => Atom.to_string(status.trust),
      "digest" => status.digest,
      "files" => status.files,
      "server_count" => length(status.servers),
      "findings" => status.findings
    }

    if previews?, do: Map.put(summary, "servers", status.servers), else: summary
  end

  # Project provenance from `fetch` travels with the entry, so the spawn
  # re-checks that the project is still trusted.
  defp test_connection(entry, provenance, opts) do
    id = "mcp-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case Application.ensure_all_started(:lemon_skills) do
      {:ok, _} ->
        try do
          case McpSession.open(id, cwd, [entry], self(), project_trust: provenance) do
            :ok ->
              tools = McpSession.tools(id)
              {:ok, %{"status" => "connected", "tool_count" => length(tools)}}

            {:error, :project_untrusted} ->
              {:error, :untrusted_project}

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

  defp render({:ok, %{"effective" => servers} = payload}, false) do
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

    render_project_trust(payload["project_trust"], false)
    0
  end

  defp render({:ok, %{"project_trust" => trust}}, false) do
    render_project_trust(trust, true)
    0
  end

  defp render({:ok, %{"status" => status}}, false) when status in ["trusted", "untrusted"] do
    IO.puts(
      "Other tools' MCP project files #{if status == "trusted", do: "trusted for this exact content", else: "no longer trusted"}. New sessions read the updated trust."
    )

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

  defp render_project_trust(nil, _verbose?), do: :ok
  defp render_project_trust(%{"trust" => "none"}, false), do: :ok

  defp render_project_trust(%{"trust" => "none", "label" => label}, true),
    do: IO.puts("No project MCP files in #{label}.")

  defp render_project_trust(trust, review?) do
    state =
      case trust["trust"] do
        "trusted" -> "trusted"
        "changed" -> "changed since trusted; nothing is started until trusted again"
        _ -> "untrusted; nothing is started until trusted"
      end

    IO.puts("Project MCP files in #{trust["label"]}: #{state}")
    IO.puts("  files: " <> Enum.join(trust["files"], ", "))

    if review? do
      Enum.each(trust["servers"], fn server ->
        IO.puts(
          "  #{server["name"]}\t#{server["provider"]}\t#{server["transport"]}\t#{server["preview"]}"
        )
      end)
    else
      IO.puts("  servers: #{trust["server_count"]}")
    end

    for %{"reason" => "host_value_reference"} = finding <- trust["findings"] do
      IO.puts(
        "  rejected #{finding["server"]} (#{finding["provider"]}): project files cannot read host values (#{Enum.join(finding["keys"], ", ")})"
      )
    end

    # The path is only offered as a command argument when it can be shown
    # exactly; otherwise the operator runs the command from that directory.
    cwd = if trust["cwd_arg"], do: " --cwd " <> trust["cwd_arg"], else: ""

    unsafe =
      if trust["cwd_arg"],
        do: "",
        else: " (run it inside that directory; its path cannot be shown safely)"

    cond do
      trust["trust"] == "trusted" ->
        :ok

      review? ->
        IO.puts(
          "  Review these files, then run: lemon mcp trust#{cwd} --digest #{trust["digest"]}#{unsafe}"
        )

      true ->
        IO.puts("  Review with: lemon mcp trust#{cwd}#{unsafe}")
    end
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

  defp error_message(:stale_digest),
    do:
      "The project's MCP files changed since that digest; run `lemon mcp trust` again and review them."

  defp error_message(:no_project_config),
    do: "No project MCP files were found in that directory."

  defp error_message(:untrusted_project),
    do:
      "This project's MCP files are not trusted; review them with `lemon mcp trust` before testing."

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
