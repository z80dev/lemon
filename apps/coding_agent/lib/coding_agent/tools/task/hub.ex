defmodule CodingAgent.Tools.Task.Hub do
  @moduledoc """
  Operator view and control of one root session's native task children: the
  TUI Agent Hub, served through the control plane.

  Membership is lineage, never a caller-supplied ID. A direct child was launched
  by one of the root's native sessions (`parent_session_id`) under the same
  routing key; a nested child was launched by an included child's native
  session. Anything else — another session's task, an `agent` delegation, a
  background run — is `:not_found`.

  Messages and cancellation reuse `Control`'s delivery and cancellation paths;
  the transcript is the same bounded projection as `history://<task_id>`.
  Projections are bounded and carry no prompts, raw paths or credentials.
  """

  alias CodingAgent.{Session, TaskStore}
  alias CodingAgent.InternalUrls.HistoryProtocol
  alias CodingAgent.Tools.Task.Control
  alias LemonAgent.Types.AgentToolResult

  @max_depth 8
  @max_candidates 512
  @max_agents 128
  @text_max 512
  @label_max 120
  @messageable ~w(queued running idle parked)

  @type root_ids :: [String.t()]

  @doc "Project every subagent of the root session, nested children included."
  @spec list(String.t(), root_ids()) :: {:ok, [map()]}
  def list(session_key, root_ids) do
    {members, live} = members(session_key, root_ids)

    agents =
      members
      |> Enum.map(fn {id, member} -> project(id, member, Map.get(live, id)) end)
      |> Enum.sort_by(&{&1.created_at_ms || 0, &1.task_id}, :desc)
      |> Enum.take(@max_agents)

    {:ok, agents}
  end

  @doc "The bounded `history://` transcript of one member task."
  @spec transcript(String.t(), root_ids(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def transcript(session_key, root_ids, task_id) do
    with {:ok, member, live} <- member(session_key, root_ids, task_id),
         {:ok, record, events} <- TaskStore.get(task_id) do
      {text, truncated?} = HistoryProtocol.render(task_id, record, events)

      {:ok,
       %{task_id: task_id, status: status(member.record, live), text: text, truncated: truncated?}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Steer a running member, or wake/revive an idle or parked one, through
  `Control.operator_send/2`. `{:ok, delivery}` may report `:failed` or
  `:outcome_unknown`; neither is safe to resend automatically.
  """
  @spec send(String.t(), root_ids(), String.t(), String.t()) ::
          {:ok, atom()} | {:error, atom()}
  def send(session_key, root_ids, task_id, text) do
    with {:ok, member, live} <- member(session_key, root_ids, task_id),
         :ok <- messageable(member.record, live) do
      case Control.operator_send(task_id, text) do
        {:ok, delivery} -> {:ok, delivery}
        {:error, reason} -> {:error, send_error(reason)}
      end
    end
  end

  @doc "Cancel a member through `Control`; cancellation is terminal."
  @spec cancel(String.t(), root_ids(), String.t()) :: :ok | {:error, atom()}
  def cancel(session_key, root_ids, task_id) do
    with {:ok, member, live} <- member(session_key, root_ids, task_id) do
      if status(member.record, live) in @messageable do
        case Control.operator_cancel(task_id) do
          :ok -> :ok
          {:error, _reason} -> {:error, :not_running}
        end
      else
        {:error, :not_running}
      end
    end
  end

  # -- membership ---------------------------------------------------------------

  defp member(session_key, root_ids, task_id) when is_binary(task_id) do
    {members, live} = members(session_key, root_ids)

    case Map.fetch(members, task_id) do
      {:ok, member} -> {:ok, member, Map.get(live, task_id)}
      :error -> {:error, :not_found}
    end
  end

  defp member(_session_key, _root_ids, _task_id), do: {:error, :not_found}

  defp members(session_key, root_ids) do
    roots = for id <- root_ids, is_binary(id) and id != "", into: %{}, do: {id, nil}

    candidates =
      if is_binary(session_key) and map_size(roots) > 0 do
        TaskStore.list(:all)
        |> Enum.filter(fn {_id, record} ->
          is_map(record) and Map.has_key?(record, :owner) and
            record[:session_key] == session_key and is_binary(record[:parent_session_id])
        end)
        |> Enum.sort_by(fn {_id, record} -> record[:inserted_at] || 0 end, :desc)
        |> Enum.take(@max_candidates)
      else
        []
      end

    live =
      if candidates == [], do: %{}, else: Control.hub_state(Enum.map(candidates, &elem(&1, 0)))

    {expand(candidates, live, roots, %{}, 0), live}
  end

  # `frontier` maps a native session ID to the task that owns it (nil for a root).
  defp expand(_candidates, _live, frontier, acc, depth)
       when depth >= @max_depth or map_size(frontier) == 0,
       do: acc

  defp expand(candidates, live, frontier, acc, depth) do
    found =
      Enum.filter(candidates, fn {id, record} ->
        not Map.has_key?(acc, id) and Map.has_key?(frontier, record[:parent_session_id])
      end)

    acc =
      Enum.reduce(found, acc, fn {id, record}, acc ->
        parent = Map.fetch!(frontier, record[:parent_session_id])
        Map.put(acc, id, %{record: record, depth: depth, parent_task_id: parent})
      end)

    next =
      for {id, record} <- found,
          session_id = child_session_id(record, Map.get(live, id)),
          is_binary(session_id),
          not Map.has_key?(frontier, session_id),
          into: %{},
          do: {session_id, id}

    expand(candidates, live, next, acc, depth + 1)
  end

  defp child_session_id(_record, %{session_id: id}) when is_binary(id), do: id
  defp child_session_id(record, _live), do: record[:session_id]

  # -- projection ---------------------------------------------------------------

  defp project(id, member, live) do
    record = member.record
    status = status(record, live)
    session_usage = live_usage(live)

    %{
      task_id: id,
      name: label(record[:name]),
      agent: label(record[:role]),
      description: text(record[:description], @text_max),
      status: status,
      parent_task_id: member.parent_task_id,
      depth: member.depth,
      model: model_label((session_usage && session_usage.model) || (live && live.model)),
      created_at_ms: ms(record[:inserted_at]),
      started_at_ms: ms(record[:started_at]),
      completed_at_ms: ms(record[:completed_at]),
      updated_at_ms: ms(record[:updated_at]),
      activity: if(status == "running", do: activity(id)),
      usage: usage(session_usage, record[:result]),
      context_percent: session_usage && session_usage.percent,
      messaging: status in @messageable and (live == nil or live.messaging),
      cancellable: status in @messageable
    }
  end

  # Control's live phase wins; a task without a control entry (for example after a
  # runtime restart) falls back to its persisted record and can no longer be woken.
  defp status(record, live) do
    case live && live.status do
      phase when phase in [:queued, :running, :idle, :parked] -> Atom.to_string(phase)
      phase when phase in [:cancelled, :killed] -> "cancelled"
      phase when phase in [:error, :aborted, :dead, :lost, :missing, :timeout] -> "failed"
      :completed -> "completed"
      _ -> record_status(record)
    end
  end

  defp record_status(record) do
    case {record[:status], record[:agent_state]} do
      {:cancelled, _} -> "cancelled"
      {_, :killed} -> "cancelled"
      {status, _} when status in [:error, :lost, :timeout] -> "failed"
      {_, :aborted} -> "failed"
      {:completed, _} -> "completed"
      {:running, _} -> "running"
      {:queued, _} -> "queued"
      _ -> "failed"
    end
  end

  defp messageable(record, live) do
    cond do
      status(record, live) not in @messageable -> {:error, :not_running}
      live == nil -> {:error, :not_resumable}
      live.messaging == false -> {:error, :not_messageable}
      true -> :ok
    end
  end

  defp send_error("Message exceeds" <> _), do: :invalid_message
  defp send_error("Message must" <> _), do: :invalid_message
  defp send_error("Task message queue is full" <> _), do: :queue_full
  defp send_error("Swarm coordinator" <> _), do: :not_messageable
  defp send_error("Agent cannot resume" <> _), do: :not_resumable
  defp send_error("Agent workspace/worktree was removed" <> _), do: :not_resumable
  defp send_error("Agent transcript is unavailable" <> _), do: :not_resumable
  defp send_error("Unknown or unavailable agent target" <> _), do: :not_resumable
  defp send_error(_), do: :not_running

  # One context read gives a live child's model, cumulative usage and context fill.
  defp live_usage(%{session: pid}) when is_pid(pid) do
    case Session.context_usage(pid) do
      {:ok, %{} = report} ->
        usage = Map.get(report, :usage) || %{}

        %{
          model: Map.get(report, :model),
          percent: number(Map.get(report, :percent_used)),
          tokens: count(Map.get(usage, :tokens)),
          cost_usd: number(Map.get(usage, :cost_usd)),
          requests: count(Map.get(usage, :assistant_messages)),
          input: count(Map.get(usage, :input)),
          output: count(Map.get(usage, :output))
        }

      _ ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp live_usage(_live), do: nil

  defp usage(%{} = live, _result),
    do: Map.take(live, [:tokens, :cost_usd, :requests, :input, :output])

  defp usage(nil, %AgentToolResult{details: %{} = details}) do
    reported = details[:usage]

    usage =
      %{
        requests: count(details[:request_count]),
        tokens: count(field(reported, :total_tokens) || field(reported, :tokens)),
        cost_usd: number(field(reported, :cost_usd) || field(field(reported, :cost), :total)),
        input: count(field(reported, :input)),
        output: count(field(reported, :output))
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if map_size(usage) == 0, do: nil, else: usage
  end

  defp usage(nil, _result), do: nil

  defp activity(task_id) do
    case TaskStore.get(task_id) do
      {:ok, _record, events} ->
        events
        |> Enum.reverse()
        |> Enum.find_value(fn
          %AgentToolResult{details: %{} = details} ->
            case details[:current_action] || details["current_action"] do
              %{} = action -> text(action[:title] || action["title"], @label_max)
              _ -> nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp model_label(%{id: id} = model) when is_binary(id) or is_atom(id) do
    provider = Map.get(model, :provider)

    [provider, id]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("/", &to_string/1)
    |> label()
  end

  defp model_label(_), do: nil

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_value, _key), do: nil

  defp label(value), do: text(value, @label_max)

  # Display text only: control characters collapse to spaces and the result is bounded.
  defp text(value, max) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(~r/[\p{Cc}\s]+/u, " ") |> String.trim() do
        "" -> nil
        plain -> bound(plain, max)
      end
    end
  end

  defp text(_value, _max), do: nil

  defp bound(plain, max) do
    if String.length(plain) <= max, do: plain, else: String.slice(plain, 0, max - 1) <> "…"
  end

  defp ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1000
  defp ms(_), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_), do: nil
end
