defmodule LemonCli.ProfileCommand do
  @moduledoc """
  Packaged CLI lifecycle and canonical-chat surface for user-managed profiles.

  The command delegates storage to `LemonCore.ProfileStore` and run submission
  to the optional router bridge, keeping `lemon_cli` independent of the router
  application while still working in the assembled Lemon runtime release.
  """

  alias LemonCore.{NodeRegistry, ProfileStore, RouterBridge}

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @common [json: :boolean, config_path: :string, home_state_dir: :string]
  @profile_fields [
    name: :string,
    description: :string,
    avatar: :string,
    model: :string,
    system_prompt: :string,
    node: :string
  ]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) do
    case args do
      ["list" | rest] -> list(rest)
      ["show" | rest] -> show(rest)
      ["create" | rest] -> create(rest)
      ["clone" | rest] -> clone(rest)
      ["rename" | rest] -> rename(rest)
      ["export" | rest] -> export_profile(rest)
      ["delete" | rest] -> delete(rest)
      ["roster" | rest] -> roster(rest)
      ["chat" | rest] -> chat(rest)
      _ -> usage_error("A profile subcommand is required")
    end
  end

  defp list(args) do
    with {:ok, opts, []} <- parse(args, @common),
         profiles <- ProfileStore.list(store_opts(opts)) do
      output(profiles, opts, &print_profile_list/1)
      @exit_ok
    else
      {:ok, _opts, rest} -> usage_error("Unexpected arguments: #{Enum.join(rest, " ")}")
      {:error, reason} -> usage_error(reason)
    end
  end

  defp show(args) do
    with {:ok, opts, [id]} <- parse(args, @common),
         {:ok, profile} <- ProfileStore.get(id, store_opts(opts)) do
      output(profile, opts, &print_profile/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile show <id> [--json]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp create(args) do
    with {:ok, opts, [id]} <- parse(args, @common ++ @profile_fields),
         attrs = profile_attrs(id, opts),
         {:ok, profile} <- ProfileStore.create(attrs, store_opts(opts)) do
      refresh_runtime_profiles()
      output(profile, opts, &print_profile/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile create <id> [options]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp clone(args) do
    with {:ok, opts, [source, id]} <- parse(args, @common ++ @profile_fields),
         attrs = profile_attrs(id, opts),
         {:ok, profile} <- ProfileStore.clone(source, attrs, store_opts(opts)) do
      refresh_runtime_profiles()
      output(profile, opts, &print_profile/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile clone <source> <new-id> [options]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp rename(args) do
    with {:ok, opts, [id, name]} <- parse(args, @common),
         {:ok, profile} <- ProfileStore.rename(id, name, store_opts(opts)) do
      refresh_runtime_profiles()
      output(profile, opts, &print_profile/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile rename <id> <name> [--json]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp export_profile(args) do
    with {:ok, opts, [id, destination]} <- parse(args, @common ++ [force: :boolean]),
         {:ok, result} <-
           ProfileStore.export(
             id,
             destination,
             Keyword.put(store_opts(opts), :force, opts[:force] || false)
           ) do
      output(result, opts, fn result ->
        IO.puts("Exported #{result["profileId"]} to #{result["path"]}")

        IO.puts(
          "Included #{result["fileCount"]} selected files; omitted #{result["omittedCount"]}; redacted #{result["redactionCount"]} values"
        )
      end)

      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile export <id> <path> [--force]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp delete(args) do
    with {:ok, opts, [id]} <- parse(args, @common ++ [confirm: :string]),
         {:ok, result} <-
           ProfileStore.delete(id, Keyword.put(store_opts(opts), :confirm, opts[:confirm])) do
      refresh_runtime_profiles()
      output(result, opts, &print_delete/1)
      @exit_ok
    else
      {:ok, _opts, _rest} ->
        usage_error("Usage: lemon profile delete <id> --confirm <id> [--json]")

      {:error, reason} ->
        operation_error(reason)
    end
  end

  defp roster(args) do
    with {:ok, opts, []} <- parse(args, @common) do
      profiles = ProfileStore.list(store_opts(opts)) |> Enum.map(&roster_entry/1)
      output(%{"profiles" => profiles, "count" => length(profiles)}, opts, &print_roster/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile roster [--json]")
      {:error, reason} -> usage_error(reason)
    end
  end

  defp chat(args) do
    spec = @common ++ [model: :string, queue_mode: :string]

    with {:ok, opts, [id | prompt_parts]} when prompt_parts != [] <- parse(args, spec),
         {:ok, profile} <- ProfileStore.get(id, store_opts(opts)),
         :ok <- ensure_chat_runtime_profile(id),
         {:ok, request} <-
           ProfileStore.chat_request(profile, Enum.join(prompt_parts, " "),
             model: opts[:model],
             queue_mode: queue_mode(opts[:queue_mode]),
             meta: %{profile_cli: true}
           ),
         {:ok, result} <- submit_chat(request, profile, opts) do
      output(result, opts, fn result ->
        IO.puts("Submitted #{result["profileId"]} chat as run #{result["runId"]}")
        IO.puts("Session: #{result["sessionKey"]}")
      end)

      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon profile chat <id> <message> [options]")
      {:error, reason} -> operation_error(reason)
    end
  end

  defp submit_chat(request, profile, opts) do
    case RouterBridge.submit_run(request) do
      {:ok, run_id} ->
        {:ok, chat_result(run_id, request, profile)}

      {:error, :unavailable} ->
        params = %{
          "id" => profile["id"],
          "prompt" => request.prompt,
          "queueMode" => to_string(request.queue_mode)
        }

        params = if opts[:model], do: Map.put(params, "model", opts[:model]), else: params

        case control_plane_client().request("profile.chat", params) do
          {:ok, %{"runId" => run_id} = result} ->
            {:ok,
             Map.merge(chat_result(run_id, request, profile), %{
               "sessionKey" => result["sessionKey"] || request.session_key,
               "node" => result["node"] || profile["node"]
             })}

          {:ok, other} ->
            {:error, {:invalid_control_plane_response, other}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_result(run_id, request, profile) do
    %{
      "runId" => run_id,
      "profileId" => profile["id"],
      "sessionKey" => request.session_key,
      "node" => profile["node"],
      "workspace" => profile["paths"]["workspace"]
    }
  end

  defp parse(args, strict) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: strict)

    if invalid == [],
      do: {:ok, opts, rest},
      else: {:error, "Invalid options: #{inspect(invalid)}"}
  end

  defp profile_attrs(id, opts) do
    @profile_fields
    |> Keyword.keys()
    |> Enum.reduce(%{"id" => id}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  defp store_opts(opts) do
    opts
    |> Keyword.take([:config_path, :home_state_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp output(value, opts, printer) do
    if opts[:json], do: IO.puts(Jason.encode!(value, pretty: true)), else: printer.(value)
  end

  defp print_profile_list([]), do: IO.puts("No user-managed profiles.")

  defp print_profile_list(profiles) do
    Enum.each(profiles, fn profile ->
      IO.puts(
        "#{profile["id"]}\t#{profile["name"]}\t#{profile["node"]}\t#{profile["canonicalSessionKey"]}"
      )
    end)
  end

  defp print_profile(profile) do
    IO.puts("Profile: #{profile["id"]} (#{profile["name"]})")
    IO.puts("Node: #{profile["node"]}")
    IO.puts("Model: #{profile["model"] || "runtime default"}")
    IO.puts("Session: #{profile["canonicalSessionKey"]}")
    IO.puts("Workspace: #{profile["paths"]["workspace"]}")
  end

  defp print_delete(result) do
    IO.puts("Deleted profile #{result["id"]}")
    if result["trashPath"], do: IO.puts("Recoverable home: #{result["trashPath"]}")
  end

  defp print_roster(%{"profiles" => profiles}) do
    Enum.each(profiles, fn profile ->
      IO.puts("#{profile["id"]}\t#{profile["node"]}\t#{profile["availability"]}")
    end)
  end

  defp roster_entry(profile) do
    node = profile["node"] || "local"

    availability =
      cond do
        node == "local" -> "local"
        node_online?(node) -> "online"
        true -> "offline"
      end

    Map.merge(Map.take(profile, ~w(id name description avatar model node canonicalSessionKey)), %{
      "availability" => availability,
      "workspace" => profile["paths"]["workspace"]
    })
  end

  defp node_online?(node) do
    Process.whereis(NodeRegistry) != nil and NodeRegistry.online?(node)
  catch
    :exit, _ -> false
  end

  defp ensure_chat_runtime_profile(id) do
    refresh_runtime_profiles()
    module = agent_profiles_module()

    cond do
      not Code.ensure_loaded?(module) -> :ok
      Process.whereis(module) == nil -> :ok
      apply(module, :exists?, [id]) -> :ok
      true -> {:error, :runtime_profile_reload_failed}
    end
  end

  defp refresh_runtime_profiles do
    module = agent_profiles_module()

    if Code.ensure_loaded?(module) and Process.whereis(module) != nil do
      _ = apply(module, :reload, [])
      _ = apply(module, :list, [])
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp agent_profiles_module, do: Module.concat(["LemonRouter", "AgentProfiles"])

  defp control_plane_client do
    Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)
  end

  defp queue_mode(nil), do: :collect
  defp queue_mode("collect"), do: :collect
  defp queue_mode("followup"), do: :followup
  defp queue_mode("steer"), do: :steer
  defp queue_mode("interrupt"), do: :interrupt
  defp queue_mode(_), do: :collect

  defp operation_error(reason) do
    IO.puts(:stderr, "Profile operation failed: #{format_reason(reason)}")
    @exit_error
  end

  defp usage_error(reason) do
    IO.puts(:stderr, reason)
    IO.puts(:stderr, "Run `lemon profile --help` for command options.")
    @exit_usage
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
