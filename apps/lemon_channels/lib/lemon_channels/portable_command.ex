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
  @public_statuses ~w(
    accepted active blocked cancelled completed error failed idle killed lost
    pending queued recorded running tracking_lost
  )

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
      {:ok, %{"name" => "bg"}} -> background(args, context)
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
    status = get(summary, :status) || "recorded"
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

  defp background("", _context), do: {:error, background_usage()}

  defp background(args, context) do
    case String.split(args, ~r/\s+/, parts: 2) do
      ["list"] ->
        list_background(context)

      ["status", id] ->
        with_background_id(id, &background_status(&1, context))

      ["result", id] ->
        with_background_id(id, &background_result(&1, context))

      ["cancel", id] ->
        with_background_id(id, &cancel_background(&1, context))

      [command] when command in ["status", "result", "cancel"] ->
        {:error, background_usage()}

      _ ->
        start_background(args, context)
    end
  end

  defp start_background(prompt, context) do
    opts =
      []
      |> maybe_put(:session_key, context[:session_key])
      |> maybe_put(:cwd, context[:cwd])
      |> maybe_put(:model, context[:model])
      |> maybe_put(:thinking_level, context[:thinking_level])

    case runtime_call(:background_start, [prompt, opts], {:error, :unavailable}) do
      {:ok, %{id: id}} when is_binary(id) ->
        background_started_result(id)

      {:ok, %{"id" => id}} when is_binary(id) ->
        background_started_result(id)

      {:error, :unavailable} ->
        {:error, "Background runs are unavailable in this Lemon runtime."}

      {:error, _reason} ->
        {:error, "Background run could not be started. Check Lemon runtime logs."}

      _ ->
        {:error, "Background run failed to start."}
    end
  end

  defp list_background(context) do
    case scoped_background_call(:background_list_scoped, context, fn session_key ->
           [session_key, []]
         end) do
      runs when is_list(runs) ->
        {:ok, render_background_list(runs)}

      {:error, :unavailable} ->
        {:error, "Background runs are unavailable in this Lemon runtime."}

      {:error, _reason} ->
        {:error, "Background runs could not be listed. Check Lemon runtime logs."}

      _ ->
        {:error, "Background runs could not be listed."}
    end
  end

  defp background_status(id, context) do
    case scoped_background_call(:background_status_scoped, context, &[id, &1]) do
      {:ok, status} when is_map(status) -> {:ok, render_background_status(status, id)}
      {:error, :not_found} -> {:error, "Background run not found."}
      {:error, :unavailable} -> {:error, "Background runs are unavailable in this Lemon runtime."}
      {:error, _reason} -> {:error, "Background status is unavailable. Check Lemon runtime logs."}
      _ -> {:error, "Background status is unavailable."}
    end
  end

  defp background_result(id, context) do
    case scoped_background_call(:background_result_scoped, context, &[id, &1]) do
      {:ok, answer} when is_binary(answer) -> {:ok, "Background result #{id}\n#{answer}"}
      {:error, :not_ready} -> {:ok, "Background run #{id} is not finished yet."}
      {:error, :not_found} -> {:error, "Background run not found."}
      {:error, :cancelled} -> {:ok, "Background run #{id} was cancelled."}
      {:error, :lost} -> {:ok, "Background run #{id} was interrupted before completion."}
      {:error, :unavailable} -> {:error, "Background runs are unavailable in this Lemon runtime."}
      {:error, _reason} -> {:error, "Background result is unavailable. Check Lemon runtime logs."}
      _ -> {:error, "Background result is unavailable."}
    end
  end

  defp cancel_background(id, context) do
    case scoped_background_call(:background_cancel_scoped, context, &[id, &1]) do
      :ok ->
        {:ok, "Cancelled background run #{id}."}

      {:error, :not_found} ->
        {:error, "Background run not found."}

      {:error, :already_terminal} ->
        {:ok, "Background run #{id} has already finished."}

      {:error, :unavailable} ->
        {:error, "Background runs are unavailable in this Lemon runtime."}

      {:error, _reason} ->
        {:error, "Background run could not be cancelled. Check Lemon runtime logs."}

      _ ->
        {:error, "Background run could not be cancelled."}
    end
  end

  defp scoped_background_call(function, context, args_fn) do
    case normalize_session_key(context[:session_key]) do
      nil ->
        {:error, :not_found}

      session_key ->
        runtime_call(function, args_fn.(session_key), {:error, :unavailable})
    end
  end

  defp normalize_session_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_session_key(_value), do: nil

  defp render_background_list(runs) do
    rows =
      runs
      |> Enum.map(&background_row/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@default_limit)

    case rows do
      [] -> "No background runs are recorded."
      _ -> Enum.join(["Background runs (#{length(rows)})" | rows], "\n")
    end
  end

  defp background_row(run) when is_map(run) do
    with id when is_binary(id) <- get(run, :id),
         true <- valid_background_id?(id) do
      "• #{id} — #{normalize_label(get(run, :status) || "recorded")}"
    else
      _ -> nil
    end
  end

  defp background_row(_), do: nil

  defp render_background_status(status, requested_id) do
    lifecycle = normalize_label(get(status, :status) || "recorded")
    result = if get(status, :result_available) == true, do: "available", else: "not available"

    "Background run #{requested_id}\nStatus: #{lifecycle}\nResult: #{result}"
  end

  defp background_started(id) do
    "Background run started: #{id}\n" <>
      "Use /bg status #{id}, /bg result #{id}, or /bg cancel #{id}."
  end

  defp background_started_result(id) do
    if valid_background_id?(id) do
      {:ok, background_started(id)}
    else
      {:error, "Background run started without a usable id. Check Lemon runtime logs."}
    end
  end

  defp background_usage do
    "Usage: /bg <prompt> | /bg list | /bg status <id> | /bg result <id> | /bg cancel <id>"
  end

  defp with_background_id(id, fun) when is_function(fun, 1) do
    if valid_background_id?(id), do: fun.(id), else: {:error, "Background run id is invalid."}
  end

  defp valid_background_id?(id) when is_binary(id) do
    byte_size(id) <= 128 and String.match?(id, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp valid_background_id?(_), do: false

  defp ask_side_question("", _context), do: {:error, "Usage: /btw <question>"}

  defp ask_side_question(question, context) do
    case context[:session_key] do
      session_key when is_binary(session_key) and session_key != "" ->
        opts = maybe_put([], :timeout_ms, context[:timeout_ms])

        case runtime_call(:side_query, [session_key, question, opts], {:error, :unavailable}) do
          {:ok, answer} when is_binary(answer) ->
            {:ok, answer}

          {:error, :unavailable} ->
            {:error, "Side questions are unavailable in this Lemon runtime."}

          {:error, _reason} ->
            {:error, "Side question could not be answered. Check Lemon runtime logs."}

          _ ->
            {:error, "Side question failed."}
        end

      _ ->
        {:error, "No current session is available for /btw."}
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
    if value in @public_statuses, do: String.replace(value, "_", " "), else: "recorded"
  end

  defp normalize_label(_value), do: "recorded"

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
