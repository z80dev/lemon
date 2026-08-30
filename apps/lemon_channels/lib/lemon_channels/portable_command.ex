defmodule LemonChannels.PortableCommand do
  @moduledoc """
  Channel-facing execution and rendering for the portable command catalog.

  This module keeps transport presentation in `lemon_channels` while calling
  the existing router, diagnostics, and registered agent-runtime boundaries.
  It never owns queue transitions or agent lifecycle state.
  """

  alias LemonChannels.CommandCatalog
  alias LemonCore.{RouterBridge, Store, UsageDiagnostics}

  @default_limit 10

  @type context :: %{
          optional(:session_key) => binary(),
          optional(:cwd) => binary(),
          optional(:model) => binary(),
          optional(:thinking_level) => binary() | atom(),
          optional(:timeout_ms) => pos_integer()
        }

  @spec handle(binary(), binary() | nil, context()) :: {:ok, binary()} | {:error, binary()}
  def handle(command, args \\ "", context \\ %{}) when is_binary(command) and is_map(context) do
    args = String.trim(args || "")

    case CommandCatalog.find(command) do
      {:ok, %{"name" => "status"}} -> {:ok, render_status(context)}
      {:ok, %{"name" => "usage"}} -> {:ok, render_usage()}
      {:ok, %{"name" => "agents"}} -> {:ok, render_tasks()}
      {:ok, %{"name" => "compress"}} -> compact(context)
      {:ok, %{"name" => name}} when name in ["commands", "help"] -> {:ok, render_help(args)}
      {:ok, %{"name" => "bg"}} -> start_background(args, context)
      {:ok, %{"name" => "btw"}} -> ask_side_question(args, context)
      {:ok, command_meta} -> {:error, usage(command_meta)}
      :error -> {:error, "Unknown command. Use /commands to see the portable Lemon commands."}
    end
  rescue
    _ -> {:error, "Command failed safely. Check the Lemon runtime logs for details."}
  catch
    :exit, _ -> {:error, "Command runtime is unavailable."}
  end

  defp render_status(context) do
    session_key = context[:session_key]

    active =
      if is_binary(session_key) and session_key != "",
        do: RouterBridge.active_run(session_key),
        else: :none

    recent =
      if is_binary(session_key) and session_key != "" do
        Store.get_run_history(session_key, limit: 1) |> List.first()
      end

    [
      "Lemon status",
      "Session: #{if(is_binary(session_key), do: "active", else: "unavailable")}",
      active_line(active),
      recent_line(recent)
    ]
    |> Enum.join("\n")
  end

  defp active_line({:ok, run_id}), do: "Run: active (#{short_id(run_id)})"
  defp active_line(_), do: "Run: idle"

  defp recent_line({run_id, run}) when is_map(run) do
    summary = get(run, :summary) || %{}
    status = get(summary, :status) || get(summary, :reason) || "recorded"
    "Latest: #{normalize_label(status)} (#{short_id(run_id)})"
  end

  defp recent_line(_), do: "Latest: none"

  defp render_usage do
    diagnostics = UsageDiagnostics.status()
    tokens = get(diagnostics, :total_tokens) || %{}
    input = integer(get(tokens, :input))
    output = integer(get(tokens, :output))
    requests = integer(get(diagnostics, :total_requests))
    cost = number(get(diagnostics, :total_cost))

    [
      "Lemon usage (today)",
      "Requests: #{requests}",
      "Tokens: #{input + output} (#{input} in / #{output} out)",
      "Cost: $#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"
    ]
    |> Enum.join("\n")
  end

  defp render_tasks do
    tasks =
      runtime_call(:list_tasks, [], [])
      |> Enum.map(&task_row/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.take(@default_limit)

    case tasks do
      [] ->
        "No native Lemon agents or delegated tasks are currently recorded."

      rows ->
        lines =
          Enum.map(rows, fn row ->
            "• #{row.id} — #{row.status}#{if(row.description == "", do: "", else: ": " <> row.description)}"
          end)

        Enum.join(["Lemon agents/tasks (#{length(rows)})" | lines], "\n")
    end
  end

  defp task_row({task_id, record}) when is_map(record) do
    %{
      id: short_id(task_id),
      status: normalize_label(get(record, :status) || "recorded"),
      description: bounded_text(get(record, :description), 100),
      updated_at:
        integer(get(record, :updated_at) || get(record, :started_at) || get(record, :inserted_at))
    }
  end

  defp task_row(_), do: nil

  defp compact(context) do
    with session_key when is_binary(session_key) and session_key != "" <- context[:session_key],
         :ok <- runtime_call(:compact_session, [session_key, []], {:error, :unavailable}) do
      {:ok, "Compacted the current Lemon session context."}
    else
      nil ->
        {:error, "No current session is available to compact."}

      "" ->
        {:error, "No current session is available to compact."}

      {:error, :session_not_found} ->
        {:error, "The current session is not live; nothing was compacted."}

      {:error, _} ->
        {:error, "Session compaction is unavailable right now."}

      _ ->
        {:error, "Session compaction is unavailable right now."}
    end
  end

  defp render_help(filter) do
    commands =
      CommandCatalog.catalog()
      |> Enum.filter(fn command ->
        filter == "" or
          String.contains?(String.downcase(command["name"]), String.downcase(filter)) or
          String.contains?(String.downcase(command["description"]), String.downcase(filter))
      end)

    case commands do
      [] ->
        "No portable Lemon commands match #{inspect(filter)}."

      rows ->
        rows
        |> Enum.group_by(& &1["category"])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {category, category_commands} ->
          [
            String.capitalize(category),
            Enum.map_join(category_commands, "\n", fn command ->
              aliases =
                case command["aliases"] do
                  [] -> ""
                  values -> " (#{Enum.join(values, ", ")})"
                end

              "#{command["command"]} #{command["arguments"]}#{aliases} — #{command["description"]}"
              |> String.replace(~r/\s+—/, " —")
            end)
          ]
        end)
        |> Enum.join("\n")
    end
  end

  defp start_background("", _context), do: {:error, "Usage: /bg <prompt>"}

  defp start_background(prompt, context) do
    opts =
      []
      |> maybe_put(:session_key, context[:session_key])
      |> maybe_put(:cwd, context[:cwd])
      |> maybe_put(:model, context[:model])
      |> maybe_put(:thinking_level, context[:thinking_level])

    case runtime_call(:background_start, [prompt, opts], {:error, :unavailable}) do
      {:ok, %{id: id}} -> {:ok, "Background run started: #{short_id(id)}"}
      {:ok, %{"id" => id}} -> {:ok, "Background run started: #{short_id(id)}"}
      {:error, :unavailable} -> {:error, "Background runs are unavailable in this Lemon runtime."}
      {:error, reason} -> {:error, "Background run failed to start: #{normalize_label(reason)}"}
      _ -> {:error, "Background run failed to start."}
    end
  end

  defp ask_side_question("", _context), do: {:error, "Usage: /btw <question>"}

  defp ask_side_question(question, context) do
    with session_key when is_binary(session_key) and session_key != "" <- context[:session_key] do
      opts = maybe_put([], :timeout_ms, context[:timeout_ms])

      case runtime_call(:side_query, [session_key, question, opts], {:error, :unavailable}) do
        {:ok, answer} when is_binary(answer) ->
          {:ok, answer}

        {:error, :unavailable} ->
          {:error, "Side questions are unavailable in this Lemon runtime."}

        {:error, reason} ->
          {:error, "Side question failed: #{normalize_label(reason)}"}

        _ ->
          {:error, "Side question failed."}
      end
    else
      _ -> {:error, "No current session is available for /btw."}
    end
  end

  defp usage(command) do
    [command["command"], command["arguments"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> then(&"Usage: #{&1}")
  end

  defp runtime_call(function, args, fallback) do
    provider = Application.get_env(:lemon_control_plane, :agent_runtime_provider)
    module_call(provider, function, args, fallback)
  end

  defp module_call(module, function, args, fallback)
       when is_atom(module) and is_atom(function) and is_list(args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      fallback
    end
  rescue
    _ -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp module_call(_, _, _, fallback), do: fallback

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(_, _), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_), do: 0

  defp number(value) when is_number(value), do: value
  defp number(_), do: 0.0

  defp normalize_label(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_label()

  defp normalize_label(value) when is_binary(value) do
    value |> String.replace("_", " ") |> bounded_text(60)
  end

  defp normalize_label(value), do: value |> inspect() |> bounded_text(60)

  defp bounded_text(value, max) when is_binary(value) do
    value |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, max)
  end

  defp bounded_text(_, _), do: ""

  defp short_id(value) when is_binary(value) and byte_size(value) > 12,
    do: String.slice(value, 0, 12)

  defp short_id(value) when is_binary(value), do: value
  defp short_id(value), do: value |> inspect() |> bounded_text(12)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
