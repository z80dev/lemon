defmodule LemonOmp.Projection do
  @moduledoc """
  Folds omp RPC events into a bounded, JSON-safe snapshot of one session.

  The projection is pure: `LemonOmp.Session` owns the process and feeds every
  decoded event through `apply_event/3`. Every string that originates in omp —
  assistant text, tool intents, todo text, errors, titles — is untrusted. It is
  stripped of control and bidi-override characters and clipped here, once, so
  every surface (control plane, TUI, CLI, agent tool) receives the same
  bounded data.

  Usage and cost accumulate from assistant `message_end` usage and are replaced
  by omp's own `get_session_stats` totals whenever the session refreshes them.
  """

  @max_title 120
  @max_activity 200
  @max_intent 160
  @max_last_text 2_000
  @max_result 4_000
  @max_error 1_000
  @max_stream_buffer 8_000
  @max_recent_tools 8
  @max_active_tools 16
  @max_todos 50
  @max_subagents 20
  @max_todo_text 200

  @unsafe ~r/[\x00-\x08\x0B-\x1F\x7F\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[@-Z\\-_]/u

  @type status :: :starting | :running | :idle | :closed | :failed

  defstruct id: nil,
            omp_session_id: nil,
            title: nil,
            cwd: nil,
            model: nil,
            thinking: nil,
            approval_mode: nil,
            owner: %{kind: :operator},
            status: :starting,
            last_turn: nil,
            activity: nil,
            started_at: nil,
            updated_at: nil,
            ended_at: nil,
            turns: 0,
            tool_calls: 0,
            active_tools: [],
            recent_tools: [],
            todos: [],
            subagents: %{},
            usage: %{
              input: 0,
              output: 0,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 0,
              cost: 0.0
            },
            context_percent: nil,
            stream_text: "",
            last_text: nil,
            result: nil,
            error: nil,
            declined_prompts: 0,
            pending_approvals: [],
            approvals: %{approved: 0, denied: 0, expired: 0},
            settling: false,
            exit: nil

  @type t :: %__MODULE__{}

  @doc "A fresh projection for a session Lemon is starting."
  @spec new(keyword()) :: t()
  def new(attrs) do
    now = now_ms()

    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      cwd: Keyword.fetch!(attrs, :cwd),
      model: Keyword.get(attrs, :model),
      thinking: Keyword.get(attrs, :thinking),
      approval_mode: Keyword.get(attrs, :approval_mode),
      owner: Keyword.get(attrs, :owner, %{kind: :operator}),
      title: title_from_prompt(Keyword.get(attrs, :prompt)),
      started_at: now,
      updated_at: now
    }
  end

  @doc "Record a shared Lemon approval awaiting a decision."
  @spec request_approval(t(), String.t(), String.t(), String.t()) :: t()
  def request_approval(state, id, tool, details) do
    approval = %{
      "id" => id,
      "tool" => clean(tool, 64),
      "details" => clean(details, 2_000),
      "requestedAt" => now_ms()
    }

    %{state | pending_approvals: state.pending_approvals ++ [approval], updated_at: now_ms()}
  end

  @doc "Remove a pending approval; abandoned dialogs do not count as decisions."
  @spec resolve_approval(t(), String.t(), :approved | :denied | :expired | nil) :: t()
  def resolve_approval(state, id, outcome) do
    {removed, pending} = Enum.split_with(state.pending_approvals, &(&1["id"] == id))

    approvals =
      if removed != [] and outcome in [:approved, :denied, :expired],
        do: Map.update!(state.approvals, outcome, &(&1 + 1)),
        else: state.approvals

    %{state | pending_approvals: pending, approvals: approvals, updated_at: now_ms()}
  end

  @doc "Apply one decoded omp event. Unknown events only touch `updated_at`."
  @spec apply_event(t(), String.t(), map()) :: t()
  def apply_event(state, type, frame) do
    state
    |> event(type, frame)
    |> Map.put(:updated_at, now_ms())
  end

  defp event(state, "agent_start", _frame),
    do: %{state | status: :running, activity: "Thinking", error: nil, stream_text: ""}

  defp event(state, "turn_start", _frame), do: %{state | turns: state.turns + 1}

  defp event(state, "message_update", %{"assistantMessageEvent" => %{"type" => kind} = ev}) do
    case kind do
      "text_delta" ->
        text = clip_tail(state.stream_text <> string(ev["delta"]), @max_stream_buffer)
        %{state | stream_text: text, activity: "Writing response"}

      kind when kind in ["thinking_start", "thinking_delta"] ->
        %{state | activity: "Thinking"}

      "toolcall_start" ->
        %{state | activity: "Preparing a tool call"}

      _other ->
        state
    end
  end

  defp event(state, "message_end", %{"message" => %{"role" => "assistant"} = message}) do
    state = state |> add_usage(message["usage"]) |> put_if(:model, message_model(message))
    text = message |> message_text() |> clean(nil)

    state =
      if text != "" do
        %{state | last_text: clip_tail(text, @max_last_text), stream_text: ""}
      else
        %{state | stream_text: ""}
      end

    case message["stopReason"] do
      "error" -> %{state | error: clean(message["errorMessage"], @max_error)}
      _ -> state
    end
  end

  defp event(state, "tool_execution_start", frame) do
    name = clean(frame["toolName"], 64)
    intent = clean(frame["intent"], @max_intent)

    tool = %{
      id: clean(frame["toolCallId"], 128),
      name: name,
      intent: blank_to_nil(intent),
      started_at: now_ms()
    }

    active = Enum.take(state.active_tools ++ [tool], -@max_active_tools)

    %{
      state
      | active_tools: active,
        tool_calls: state.tool_calls + 1,
        activity: tool_activity(name, intent)
    }
  end

  defp event(state, "tool_execution_end", frame) do
    id = clean(frame["toolCallId"], 128)
    {finished, active} = Enum.split_with(state.active_tools, &(&1.id == id))
    started = List.first(finished)
    name = clean(frame["toolName"], 64)

    recent = %{
      name: name,
      intent: started && started.intent,
      is_error: frame["isError"] == true,
      duration_ms: started && max(now_ms() - started.started_at, 0)
    }

    state = %{
      state
      | active_tools: active,
        recent_tools: Enum.take(state.recent_tools ++ [recent], -@max_recent_tools),
        activity:
          case List.last(active) do
            nil -> "Thinking"
            tool -> tool_activity(tool.name, tool.intent)
          end
    }

    case {name, get_in(frame, ["result", "details", "phases"])} do
      {"todo", phases} when is_list(phases) -> %{state | todos: todos_from_phases(phases)}
      _ -> state
    end
  end

  defp event(state, "todo_auto_clear", _frame), do: %{state | todos: []}

  defp event(state, "auto_compaction_start", _frame),
    do: %{state | activity: "Compacting context"}

  defp event(state, "auto_retry_start", _frame),
    do: %{state | activity: "Retrying after a provider error"}

  defp event(state, "model_changed", frame) do
    case model_label(frame["model"]) do
      nil -> state
      model -> %{state | model: model}
    end
  end

  defp event(state, "subagent_lifecycle", %{"payload" => payload}) when is_map(payload),
    do: upsert_subagent(state, payload, clean(payload["status"], 32))

  defp event(state, "subagent_progress", %{"payload" => payload}) when is_map(payload),
    do: upsert_subagent(state, payload, nil)

  defp event(state, "agent_end", frame) do
    # The turn's verdict arrives next in `prompt_result` (or `session_settled`);
    # settling here would publish a finished turn without its outcome.
    if frame["isTerminal"] == false or state.status != :running do
      state
    else
      %{state | activity: "Finishing turn", settling: true}
    end
  end

  defp event(state, "prompt_result", frame) do
    turn =
      case frame["status"] do
        status when status in ["completed", "error", "aborted"] -> String.to_atom(status)
        _ -> state.last_turn
      end

    error =
      case frame["error"] do
        %{"message" => message} -> clean(message, @max_error)
        _ -> state.error
      end

    settle(%{state | last_turn: turn, error: error})
  end

  defp event(state, "session_settled", _frame), do: settle(state)

  defp event(state, _type, _frame), do: state

  @doc "Mark the in-flight turn finished (the process stays open)."
  @spec settle(t()) :: t()
  def settle(%__MODULE__{status: status} = state) when status in [:closed, :failed], do: state

  def settle(state) do
    result =
      case state.last_text do
        nil -> state.result
        text -> clip_head(text, @max_result)
      end

    %{
      state
      | status: :idle,
        activity: nil,
        active_tools: [],
        stream_text: "",
        settling: false,
        result: result
    }
  end

  @doc "Merge fields from an omp `get_state` response."
  @spec apply_state(t(), map()) :: t()
  def apply_state(state, data) when is_map(data) do
    state
    |> put_if(:omp_session_id, clean(data["sessionId"], 128))
    |> put_if(:model, model_label(data["model"]))
    |> put_if(:thinking, clean(data["thinkingLevel"], 16))
    |> put_if(:title, clean(data["sessionName"], @max_title))
    |> put_if(:context_percent, percent(get_in(data, ["contextUsage", "percent"])))
    |> then(fn state ->
      case data["todoPhases"] do
        phases when is_list(phases) and phases != [] ->
          %{state | todos: todos_from_phases(phases)}

        _ ->
          state
      end
    end)
  end

  def apply_state(state, _data), do: state

  @doc "Replace usage with omp's own `get_session_stats` totals."
  @spec apply_stats(t(), map()) :: t()
  def apply_stats(state, %{"tokens" => tokens} = data) when is_map(tokens) do
    usage = %{
      input: int(tokens["input"]),
      output: int(tokens["output"]),
      cache_read: int(tokens["cacheRead"]),
      cache_write: int(tokens["cacheWrite"]),
      total_tokens: int(tokens["total"]),
      cost: number(data["cost"])
    }

    state
    |> Map.put(:usage, usage)
    |> put_if(:omp_session_id, clean(data["sessionId"], 128))
    |> put_if(:context_percent, percent(get_in(data, ["contextUsage", "percent"])))
  end

  def apply_stats(state, _data), do: state

  @doc "Record a terminal process outcome."
  @spec finish(t(), :closed | :failed, map()) :: t()
  def finish(state, status, exit) do
    error =
      case {status, exit[:error]} do
        {:failed, message} when is_binary(message) -> clean(message, @max_error)
        _ -> state.error
      end

    %{
      state
      | status: status,
        activity: nil,
        active_tools: [],
        stream_text: "",
        settling: false,
        ended_at: now_ms(),
        updated_at: now_ms(),
        error: error,
        exit: %{code: exit[:code], reason: exit[:reason]}
    }
  end

  @doc "The JSON-safe wire form (camelCase string keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = state) do
    %{
      "id" => state.id,
      "ompSessionId" => state.omp_session_id,
      "title" => state.title,
      "cwd" => state.cwd,
      "model" => state.model,
      "thinking" => state.thinking,
      "approvalMode" => state.approval_mode,
      "owner" => owner_wire(state.owner),
      "status" => Atom.to_string(state.status),
      "lastTurn" => state.last_turn && Atom.to_string(state.last_turn),
      "activity" =>
        case state.pending_approvals do
          [approval | _] -> "Waiting for approval: #{approval["tool"]}"
          [] -> state.activity
        end,
      "startedAt" => state.started_at,
      "updatedAt" => state.updated_at,
      "endedAt" => state.ended_at,
      "turns" => state.turns,
      "toolCalls" => state.tool_calls,
      "activeTools" =>
        Enum.map(state.active_tools, fn tool ->
          %{
            "id" => tool.id,
            "name" => tool.name,
            "intent" => tool.intent,
            "startedAt" => tool.started_at
          }
        end),
      "recentTools" =>
        Enum.map(state.recent_tools, fn tool ->
          %{
            "name" => tool.name,
            "intent" => tool.intent,
            "isError" => tool.is_error,
            "durationMs" => tool.duration_ms
          }
        end),
      "todos" =>
        Enum.map(state.todos, fn todo ->
          %{"phase" => todo.phase, "content" => todo.content, "status" => todo.status}
        end),
      "subagents" =>
        state.subagents
        |> Map.values()
        |> Enum.sort_by(& &1.order)
        |> Enum.map(fn sub ->
          %{
            "id" => sub.id,
            "agent" => sub.agent,
            "status" => sub.status,
            "description" => sub.description
          }
        end),
      "usage" => %{
        "input" => state.usage.input,
        "output" => state.usage.output,
        "cacheRead" => state.usage.cache_read,
        "cacheWrite" => state.usage.cache_write,
        "totalTokens" => state.usage.total_tokens,
        "cost" => state.usage.cost
      },
      "contextPercent" => state.context_percent,
      "lastText" => current_text(state),
      "result" => state.result,
      "error" => state.error,
      "declinedPrompts" => state.declined_prompts,
      "pendingApprovals" => state.pending_approvals,
      "approvals" => %{
        "approved" => state.approvals.approved,
        "denied" => state.approvals.denied,
        "expired" => state.approvals.expired
      },
      "exit" => state.exit && %{"code" => state.exit.code, "reason" => to_s(state.exit.reason)}
    }
  end

  @doc """
  A bounded plain-text report of what the session is doing, for chat and the
  CLI. It quotes omp output, which callers must treat as untrusted.
  """
  @spec summary(map()) :: String.t()
  def summary(wire) when is_map(wire) do
    usage = wire["usage"] || %{}
    todos = wire["todos"] || []
    done = Enum.count(todos, &(&1["status"] in ["completed", "done"]))

    lines =
      [
        "omp session #{wire["id"]}" <>
          if(wire["ompSessionId"], do: " (omp #{wire["ompSessionId"]})", else: ""),
        "Title: #{wire["title"] || "untitled"}",
        "Workspace: #{wire["cwd"]}",
        "Status: #{status_line(wire)}",
        wire["activity"] && "Current activity: #{wire["activity"]}",
        wire["model"] && "Model: #{wire["model"]}",
        "Progress: #{wire["turns"]} turns, #{wire["toolCalls"]} tool calls" <>
          if(todos != [], do: ", todos #{done}/#{length(todos)} done", else: ""),
        "Usage: #{usage["totalTokens"] || 0} tokens" <>
          cost_suffix(usage["cost"]) <> context_suffix(wire["contextPercent"]),
        active_tools_line(wire["activeTools"] || []),
        recent_tools_line(wire["recentTools"] || []),
        todos_block(todos),
        subagents_line(wire["subagents"] || []),
        pending_approvals_line(wire["pendingApprovals"] || []),
        wire["declinedPrompts"] > 0 &&
          "Declined #{wire["declinedPrompts"]} interactive omp prompt(s) (Lemon runs omp headless).",
        wire["error"] && "Error: #{wire["error"]}",
        text_block(wire)
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(lines, "\n")
  end

  defp status_line(%{"status" => "idle", "lastTurn" => turn}) when is_binary(turn),
    do: "idle (last turn #{turn}; open for follow-ups)"

  defp status_line(%{"status" => "idle"}), do: "idle (open for follow-ups)"

  defp status_line(%{"status" => "closed", "lastTurn" => turn}) when is_binary(turn),
    do: "closed (last turn #{turn}; resumable)"

  defp status_line(%{"status" => status}), do: status

  defp cost_suffix(cost) when is_number(cost) and cost > 0,
    do: ", $" <> :erlang.float_to_binary(cost / 1, decimals: 4)

  defp cost_suffix(_cost), do: ""

  defp context_suffix(percent) when is_number(percent),
    do: ", context #{:erlang.float_to_binary(percent / 1, decimals: 1)}%"

  defp context_suffix(_percent), do: ""

  defp pending_approvals_line([]), do: nil

  defp pending_approvals_line(approvals) do
    "Pending approvals: " <>
      Enum.map_join(approvals, ", ", &"#{&1["tool"]} (#{&1["id"]})") <>
      ". Resolve through Lemon's approval prompts/channel buttons or operator exec.approval.resolve."
  end

  defp active_tools_line([]), do: nil

  defp active_tools_line(tools) do
    "Running: " <>
      Enum.map_join(tools, "; ", fn tool -> tool_activity(tool["name"], tool["intent"]) end)
  end

  defp recent_tools_line([]), do: nil

  defp recent_tools_line(tools) do
    "Recent tools: " <>
      Enum.map_join(tools, ", ", fn tool ->
        tool["name"] <> if(tool["isError"], do: " (failed)", else: "")
      end)
  end

  defp todos_block([]), do: nil

  defp todos_block(todos) do
    "Todos:\n" <>
      Enum.map_join(todos, "\n", fn todo -> "  [#{todo["status"]}] #{todo["content"]}" end)
  end

  defp subagents_line([]), do: nil

  defp subagents_line(subs) do
    "Subagents: " <>
      Enum.map_join(subs, ", ", fn sub -> "#{sub["agent"] || sub["id"]} (#{sub["status"]})" end)
  end

  defp text_block(%{"status" => "running", "lastText" => text}) when is_binary(text),
    do: "Latest output:\n" <> text

  defp text_block(%{"result" => text}) when is_binary(text), do: "Last result:\n" <> text
  defp text_block(%{"lastText" => text}) when is_binary(text), do: "Latest output:\n" <> text
  defp text_block(_wire), do: nil

  @doc "Strip unsafe characters and clip an untrusted string; `nil` max means no clip."
  @spec clean(term(), pos_integer() | nil) :: String.t()
  def clean(value, max) when is_binary(value) do
    # Invalid byte sequences (e.g. a stderr tail cut mid-character) become
    # U+FFFD instead of discarding the whole string.
    value = if String.valid?(value), do: value, else: String.replace_invalid(value)

    value =
      value
      |> String.replace(@ansi, "")
      |> String.replace("\r\n", "\n")
      |> String.replace(@unsafe, "")

    if max, do: clip_head(value, max), else: value
  end

  def clean(_value, _max), do: ""

  @doc false
  def title_from_prompt(prompt) when is_binary(prompt) do
    prompt
    |> clean(nil)
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> clip_head(@max_title)
    |> blank_to_nil()
  end

  def title_from_prompt(_prompt), do: nil

  defp current_text(%{status: :running, stream_text: text}) when text != "",
    do: text |> clean(nil) |> clip_tail(@max_last_text)

  defp current_text(state), do: state.last_text

  defp tool_activity(name, intent) when is_binary(intent) and intent != "",
    do: clip_head("Running #{name} — #{intent}", @max_activity)

  defp tool_activity(name, _intent), do: "Running #{name}"

  defp add_usage(state, %{} = usage) do
    cost =
      case usage["cost"] do
        %{"total" => total} -> number(total)
        _ -> 0.0
      end

    current = state.usage

    %{
      state
      | usage: %{
          input: current.input + int(usage["input"]),
          output: current.output + int(usage["output"]),
          cache_read: current.cache_read + int(usage["cacheRead"]),
          cache_write: current.cache_write + int(usage["cacheWrite"]),
          total_tokens: current.total_tokens + int(usage["totalTokens"]),
          cost: current.cost + cost
        }
    }
  end

  defp add_usage(state, _usage), do: state

  defp message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  defp message_text(_message), do: ""

  defp todos_from_phases(phases) do
    phases
    |> Enum.flat_map(fn
      %{"tasks" => tasks} = phase when is_list(tasks) ->
        phase_name = clean(phase["name"], 80)

        Enum.flat_map(tasks, fn
          %{"content" => content} = task ->
            [
              %{
                phase: phase_name,
                content: clean(content, @max_todo_text),
                status: clean(task["status"], 32)
              }
            ]

          _ ->
            []
        end)

      _ ->
        []
    end)
    |> Enum.take(@max_todos)
  end

  defp upsert_subagent(state, payload, status) do
    key =
      case {payload["index"], payload["id"]} do
        {index, _} when is_integer(index) -> {:index, index}
        {_, id} when is_binary(id) -> {:id, id}
        _ -> nil
      end

    cond do
      is_nil(key) ->
        state

      not Map.has_key?(state.subagents, key) and map_size(state.subagents) >= @max_subagents ->
        state

      true ->
        existing =
          Map.get(state.subagents, key, %{
            id: nil,
            agent: nil,
            status: "running",
            description: nil,
            order: map_size(state.subagents)
          })

        updated = %{
          existing
          | id: blank_to_nil(clean(payload["id"], 128)) || existing.id,
            agent: blank_to_nil(clean(payload["agent"], 64)) || existing.agent,
            status: normalize_subagent_status(status) || existing.status,
            description:
              blank_to_nil(clean(payload["description"] || payload["task"], @max_intent)) ||
                existing.description
        }

        %{state | subagents: Map.put(state.subagents, key, updated)}
    end
  end

  defp normalize_subagent_status("started"), do: "running"
  defp normalize_subagent_status(""), do: nil
  defp normalize_subagent_status(nil), do: nil
  defp normalize_subagent_status(status), do: status

  defp model_label(%{"provider" => provider, "id" => id})
       when is_binary(provider) and is_binary(id),
       do: clean("#{provider}/#{id}", 128)

  defp model_label(model) when is_binary(model) and model != "", do: clean(model, 128)
  defp model_label(_model), do: nil

  defp message_model(%{"provider" => provider, "model" => model})
       when is_binary(provider) and is_binary(model),
       do: clean("#{provider}/#{model}", 128)

  defp message_model(_message), do: nil

  defp owner_wire(%{kind: :agent, session_key: key}),
    do: %{"kind" => "agent", "sessionKey" => key}

  defp owner_wire(_owner), do: %{"kind" => "operator"}

  defp put_if(state, _key, nil), do: state
  defp put_if(state, _key, ""), do: state
  defp put_if(state, key, value), do: Map.put(state, key, value)

  defp percent(value) when is_number(value), do: Float.round(value / 1, 2)
  defp percent(_value), do: nil

  defp int(value) when is_integer(value) and value >= 0, do: value
  defp int(value) when is_float(value) and value >= 0, do: trunc(value)
  defp int(_value), do: 0

  defp number(value) when is_number(value) and value >= 0, do: value / 1
  defp number(_value), do: 0.0

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp to_s(nil), do: nil
  defp to_s(value) when is_atom(value), do: Atom.to_string(value)
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: inspect(value)

  @doc false
  def clip_head(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp clip_tail(text, max) do
    if String.length(text) > max, do: "…" <> String.slice(text, -(max - 1), max - 1), else: text
  end

  defp now_ms, do: System.system_time(:millisecond)
end
