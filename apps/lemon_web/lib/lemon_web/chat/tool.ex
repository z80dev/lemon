defmodule LemonWeb.Chat.Tool do
  @moduledoc """
  Normalized tool-call record for the transcript.

  Live `agent` `tool_use` events (`LemonControlPlane.EventBridge.project/1`)
  and `chat.history` `tool_use`/`tool_result` rows both become one map keyed by
  the tool-call identity, so a card hydrated from history is updated in place
  by replayed or later live events instead of being duplicated.

  Only visible text reaches a card: partial results keep their text content
  blocks, never thinking blocks or arbitrary metadata, and structured values
  are redacted before they are formatted.
  """

  @text_limit 64_000
  @list_limit 400

  @type status :: :running | :done | :failed | :cancelled | :completed | :unknown

  @doc "DOM id for a tool-call identity."
  @spec dom_id(String.t()) :: String.t()
  def dom_id(key), do: "tool-" <> digest(key)

  @doc "Builds a tool record from a projected live `tool_use` payload."
  @spec from_live(map(), integer()) :: map() | nil
  def from_live(payload, now_ms) do
    action = f(payload, :action) || %{}
    detail = map(f(action, :detail))
    key = string(f(detail, :tool_call_id)) || string(f(action, :id))

    if key do
      phase = phase(f(payload, :phase))
      ok = f(payload, :ok)

      %{
        id: dom_id(key),
        kind: :tool,
        key: key,
        name: tool_name(f(detail, :name), f(action, :kind)),
        title: string(f(action, :title)),
        phase: phase,
        ok: if(is_boolean(ok), do: ok),
        args: map(f(detail, :args)),
        result: result_text(detail),
        partial: visible_text(f(detail, :partial_result)),
        details: map(f(detail, :details)),
        result_meta: map(f(detail, :result_meta)),
        message: string(f(payload, :message)),
        parent: string(f(detail, :parent_action_id)),
        started_ms: now_ms,
        completed_ms: if(phase == "completed", do: now_ms),
        duration_ms: nil
      }
      |> finalize()
    end
  end

  @doc "Builds a tool record from a `chat.history` tool row."
  @spec from_history(map()) :: map() | nil
  def from_history(row) do
    case string(row["toolCallId"]) do
      nil ->
        nil

      key ->
        details = map(row["details"])
        phase = phase(row["phase"])
        content = string(row["content"])

        %{
          id: dom_id(key),
          kind: :tool,
          key: key,
          name: tool_name(row["toolName"], nil),
          title: string(row["title"]),
          phase: phase,
          ok: if(is_boolean(row["ok"]), do: row["ok"]),
          args: map(row["arguments"]),
          result: if(phase == "completed", do: content),
          partial: if(phase != "completed", do: content),
          details:
            if(row["cancelled"] == true,
              do: Map.put_new(details, "cancelled", true),
              else: details
            ),
          result_meta: %{},
          message: nil,
          parent: nil,
          started_ms: row["timestampMs"],
          completed_ms: nil,
          duration_ms: if(is_integer(row["durationMs"]), do: row["durationMs"])
        }
        |> finalize()
    end
  end

  @doc """
  Folds a newer record for the same call into `old`. A terminal record is never
  replaced by a later non-terminal one (replays after completion), and fields a
  later phase omits (arguments, title) are kept.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(nil, new), do: new

  def merge(%{phase: "completed"} = old, %{phase: phase}) when phase != "completed", do: old

  def merge(%{phase: "unknown"} = old, %{phase: phase})
      when phase not in ["completed", "unknown"],
      do: old

  def merge(old, new) do
    started = old.started_ms || new.started_ms

    duration =
      new.duration_ms || old.duration_ms ||
        if(new.phase == "completed" and is_integer(started) and is_integer(new.completed_ms),
          do: max(new.completed_ms - started, 0)
        )

    %{
      new
      | title: new.title || old.title,
        args: if(new.args == %{}, do: old.args, else: new.args),
        name: if(new.name == "tool", do: old.name, else: new.name),
        partial: new.partial || (new.phase != "completed" && old.partial) || nil,
        parent: new.parent || old.parent,
        started_ms: started,
        duration_ms: duration
    }
    |> finalize()
  end

  defp finalize(tool) do
    status = status(tool.phase, tool.ok, tool.details)

    Map.merge(tool, %{status: status, type: type(tool.name), notice: notice(tool.details, status)})
  end

  # ── Status ──────────────────────────────────────────────────────────────

  defp status("completed", ok, details) do
    cond do
      details["cancelled"] == true or details[:cancelled] == true or
          f(details, :error_type) in ["aborted", :aborted] ->
        :cancelled

      ok == false ->
        :failed

      ok == true ->
        :done

      true ->
        :completed
    end
  end

  defp status("unknown", _ok, _details), do: :unknown
  defp status(_phase, _ok, _details), do: :running

  defp notice(details, :cancelled) do
    cond do
      f(details, :outcome) == "not_started" or f(details, :not_started) == true ->
        "Cancelled before the tool started."

      f(details, :outcome) == "unknown" or f(details, :outcome_unknown) == true ->
        "Cancelled. The tool may have made changes; its final outcome is unknown."

      true ->
        nil
    end
  end

  defp notice(_details, :unknown), do: "The tool's final outcome is unknown."
  defp notice(_details, _status), do: nil

  @doc "The text a card shows as the tool's output for its status."
  @spec output(map()) :: String.t() | nil
  def output(%{status: :running} = tool), do: tool.partial
  def output(%{status: :cancelled} = tool), do: tool.partial || tool.result
  def output(tool), do: tool.result || tool.partial

  # ── Types ───────────────────────────────────────────────────────────────

  @doc "Card type for a tool name."
  @spec type(String.t()) :: atom()
  def type(name) do
    case String.downcase(name || "") do
      n when n in ~w(bash bash_output kill_process exec shell) -> :bash
      n when n in ~w(read read_file view) -> :read
      n when n in ~w(edit write patch multiedit multi_edit apply_patch hashline_edit) -> :edit
      n when n in ~w(grep find ls glob search) -> :search
      n when n in ~w(todo todowrite todo_write todoread todo_read) -> :todo
      n when n in ~w(task agent) -> :task
      n when n in ~w(webfetch websearch web_fetch web_search fetch) -> :web
      "browser" <> _ -> :browser
      _ -> :generic
    end
  end

  @doc "Icon for a card type."
  def icon(:bash), do: "terminal"
  def icon(:read), do: "file-text"
  def icon(:edit), do: "file-pen"
  def icon(:search), do: "search"
  def icon(:todo), do: "list-checks"
  def icon(:task), do: "network"
  def icon(:web), do: "globe"
  def icon(:browser), do: "monitor"
  def icon(_), do: "wrench"

  # ── Field views used by the cards ───────────────────────────────────────

  @doc "One-line subject for the card header."
  @spec subject(map()) :: String.t() | nil
  def subject(%{type: :bash} = tool), do: first_line(arg(tool, :command)) || tool.title

  def subject(%{type: type} = tool) when type in [:read, :edit] do
    arg(tool, :path) || arg(tool, :file_path) || f(tool.details, :path) || tool.title
  end

  def subject(%{type: :search} = tool) do
    pattern = arg(tool, :pattern) || arg(tool, :query)
    path = arg(tool, :path)

    cond do
      pattern && path -> "#{pattern} in #{path}"
      pattern -> pattern
      path -> path
      true -> tool.title
    end
  end

  def subject(%{type: :web} = tool), do: arg(tool, :url) || arg(tool, :query) || tool.title

  def subject(%{type: :task} = tool) do
    arg(tool, :description) || string(f(tool.details, :description)) ||
      first_line(arg(tool, :prompt)) ||
      tool.title
  end

  def subject(%{type: :browser} = tool),
    do: arg(tool, :url) || arg(tool, :selector) || arg(tool, :text) || tool.title

  def subject(tool) do
    case tool.title do
      title when is_binary(title) and title != tool.name -> String.replace(title, "`", "")
      _ -> nil
    end
  end

  @doc "String argument by key."
  def arg(tool, key) do
    case f(tool.args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc "Exit status for command cards."
  def exit_code(tool) do
    Enum.find_value([tool.details, f(tool.result_meta, :command) || %{}], fn map ->
      case f(map, :exit_code) do
        code when is_integer(code) -> code
        _ -> nil
      end
    end)
  end

  @doc "Arguments formatted for the generic view."
  def args_text(tool), do: format(tool.args)

  @doc "Read cards: first line number of the shown content."
  def start_line(tool) do
    case f(tool.details, :start_line) || f(tool.args, :offset) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  @doc "Read cards: \"lines 10–40\" when a range was requested."
  def line_range(tool) do
    offset = f(tool.args, :offset)
    limit = f(tool.args, :limit)

    cond do
      is_integer(offset) and is_integer(limit) -> "lines #{offset}–#{offset + limit - 1}"
      is_integer(offset) -> "from line #{offset}"
      is_integer(limit) -> "first #{limit} lines"
      true -> nil
    end
  end

  @doc "Language hint from a file path (extension), for highlight.js."
  def language(path) when is_binary(path) do
    case Path.extname(path) do
      "." <> ext when ext != "" -> String.downcase(ext)
      _ -> if Path.basename(path) == "Dockerfile", do: "dockerfile"
    end
  end

  def language(_), do: nil

  @doc """
  Unified diff lines for edit/write/patch cards as `{class, text}` tuples:
  `:add`, `:del`, `:hunk`, `:meta` or `:ctx`.
  """
  @spec diff_lines(map()) :: [{atom(), String.t()}] | nil
  def diff_lines(tool) do
    cond do
      diff = string(f(tool.details, :diff)) ->
        diff |> String.split("\n") |> Enum.take(@list_limit) |> Enum.map(&classify_diff/1)

      patch = arg(tool, :patch_text) || arg(tool, :patch) || arg(tool, :input) ->
        patch |> String.split("\n") |> Enum.take(@list_limit) |> Enum.map(&classify_diff/1)

      tool.name == "write" and is_binary(arg(tool, :content)) ->
        lines = tool |> arg(:content) |> String.split("\n")

        [{:hunk, "@@ new file · #{length(lines)} lines @@"}] ++
          (lines |> Enum.take(@list_limit) |> Enum.map(&{:add, "+" <> &1}))

      is_binary(f(tool.args, :old_text)) or is_binary(f(tool.args, :new_text)) or
          is_binary(f(tool.args, :old_string)) ->
        old = f(tool.args, :old_text) || f(tool.args, :old_string) || ""
        new = f(tool.args, :new_text) || f(tool.args, :new_string) || ""
        first = f(tool.details, :first_changed_line)
        header = if is_integer(first), do: "@@ line #{first} @@", else: "@@ edit @@"

        [{:hunk, header}] ++
          (old |> String.split("\n") |> Enum.take(@list_limit) |> Enum.map(&{:del, "-" <> &1})) ++
          (new |> String.split("\n") |> Enum.take(@list_limit) |> Enum.map(&{:add, "+" <> &1}))

      true ->
        nil
    end
  end

  defp classify_diff("+++" <> _ = line), do: {:meta, line}
  defp classify_diff("---" <> _ = line), do: {:meta, line}
  defp classify_diff("@@" <> _ = line), do: {:hunk, line}
  defp classify_diff("+" <> _ = line), do: {:add, line}
  defp classify_diff("-" <> _ = line), do: {:del, line}
  defp classify_diff("diff " <> _ = line), do: {:meta, line}
  defp classify_diff("index " <> _ = line), do: {:meta, line}
  defp classify_diff(line), do: {:ctx, line}

  @doc "`{added, removed}` counts for a diff."
  def diff_stats(lines) when is_list(lines) do
    Enum.reduce(lines, {0, 0}, fn
      {:add, _}, {a, d} -> {a + 1, d}
      {:del, _}, {a, d} -> {a, d + 1}
      _, acc -> acc
    end)
  end

  def diff_stats(_), do: {0, 0}

  @doc "Search cards: result rows and a count/truncation summary."
  def search_rows(tool) do
    case output(tool) do
      text when is_binary(text) ->
        text |> String.split("\n", trim: true) |> Enum.take(@list_limit)

      _ ->
        []
    end
  end

  def search_count(tool) do
    Enum.find_value([:match_count, :count, :total, :files_count], fn key ->
      case f(tool.details, key) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end) || length(search_rows(tool))
  end

  def search_truncated?(tool), do: f(tool.details, :truncated) == true

  @doc "Checklist entries (`[%{content, status}]`) and progress counts for todo cards."
  def todos(tool) do
    list =
      Enum.find_value(
        [
          f(tool.details, :todos),
          f(tool.details, :entries),
          f(tool.details, :items),
          f(tool.args, :todos),
          f(tool.args, :entries)
        ],
        &if(is_list(&1) and &1 != [], do: &1)
      ) || []

    list
    |> Enum.filter(&is_map/1)
    |> Enum.take(100)
    |> Enum.map(fn entry ->
      %{
        content:
          string(f(entry, :content)) || string(f(entry, :title)) || string(f(entry, :text)) || "",
        status: string(f(entry, :status)) || "pending"
      }
    end)
  end

  @doc "Task cards: status, current action and child identifiers."
  def task_info(tool) do
    details = tool.details

    %{
      status: string(f(details, :status)),
      current: current_action(f(details, :current_action)),
      agent: string(f(details, :agent_id)) || arg(tool, :agent_id) || arg(tool, :subagent_type),
      task_id: string(f(details, :task_id)) || arg(tool, :task_id),
      role: string(f(details, :role))
    }
  end

  defp current_action(%{} = action), do: string(f(action, :title)) || string(f(action, :kind))
  defp current_action(value) when is_binary(value), do: value
  defp current_action(_), do: nil

  # ── Text extraction ─────────────────────────────────────────────────────

  defp result_text(detail) do
    text(f(detail, :result_full)) || text(f(detail, :result))
  end

  defp text(value) when is_binary(value), do: bound(value)

  defp text(value) when is_map(value) do
    if f(value, :type) != nil or f(value, :content) != nil,
      do: visible_text(value),
      else: format(value)
  end

  defp text(value) when is_list(value), do: visible_text(value)
  defp text(nil), do: nil
  defp text(value), do: format(value)

  @doc false
  def visible_text(text) when is_binary(text) and text != "", do: bound(text)

  def visible_text(blocks) when is_list(blocks) do
    case blocks |> Enum.map(&visible_text/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      parts -> parts |> Enum.join("\n") |> bound()
    end
  end

  def visible_text(value) when is_map(value) do
    case f(value, :type) do
      type when type in [:text, "text"] -> visible_text(f(value, :text))
      nil -> visible_text(f(value, :content)) || visible_text(f(value, :output))
      _ -> nil
    end
  end

  def visible_text(_value), do: nil

  @doc false
  def format(value) when value in [nil, "", %{}, []], do: nil
  def format(value) when is_binary(value), do: bound(value)

  def format(value) when is_map(value) or is_list(value) do
    value
    |> redact()
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, json} -> bound(json)
      {:error, _} -> value |> inspect(pretty: true, limit: 50) |> bound()
    end
  rescue
    _ -> value |> inspect(pretty: true, limit: 50) |> bound()
  end

  def format(value), do: value |> inspect(limit: 50) |> bound()

  defp redact(value) when is_map(value) and not is_struct(value), do: LemonCore.Redact.map(value)
  defp redact(value), do: value

  defp bound(text) when byte_size(text) > @text_limit,
    do: String.slice(text, 0, @text_limit) <> "\n…"

  defp bound(text), do: text

  # ── Small helpers ───────────────────────────────────────────────────────

  defp tool_name(name, kind) do
    case string(name) || string(kind) do
      nil -> "tool"
      name -> LemonCore.Redact.text(name)
    end
  end

  defp phase(value) when value in [:completed, "completed"], do: "completed"
  defp phase(value) when value in [:updated, "updated"], do: "updated"
  defp phase(value) when value in [:unknown, "unknown"], do: "unknown"
  defp phase(_), do: "started"

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 300)

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false) |> binary_part(0, 16)

  defp map(value) when is_map(value) and not is_struct(value), do: value
  defp map(_), do: %{}

  defp string(value) when is_binary(value) and value != "", do: value

  defp string(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp string(_), do: nil

  @doc false
  def f(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def f(_map, _key), do: nil
end
