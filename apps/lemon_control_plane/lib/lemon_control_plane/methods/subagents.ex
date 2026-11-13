defmodule LemonControlPlane.Methods.SubagentSupport do
  @moduledoc false
  # Shared validation, projection and error mapping for the Agent Hub's
  # `subagents.*` methods. The runtime decides membership: a task outside the
  # given session's lineage is not found. Every runtime value is untrusted here;
  # rows and fields that do not fit the bounded projection are dropped.

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.AgentRuntime

  @statuses ~w(queued running idle parked completed failed cancelled)
  @deliveries ~w(injected woken revived failed outcome_unknown)a
  @accepted [:injected, :woken, :revived]
  @max_id_bytes 256
  @max_label_bytes 512
  @max_text_bytes 65_536
  @max_message_bytes 32 * 1024

  def call(function, args), do: AgentRuntime.call(function, args, {:error, :unavailable})

  def session_key(params), do: NativeSessions.string(params || %{}, "sessionKey", 1024)
  def task_id(params), do: NativeSessions.string(params || %{}, "taskId", @max_id_bytes)

  def message(params) do
    case NativeSessions.string(params || %{}, "message", @max_message_bytes) do
      {:ok, message} -> {:ok, message}
      _ -> NativeSessions.invalid("message must be non-empty text of at most 32 KiB")
    end
  end

  def project_agents(agents) when is_list(agents) do
    {:ok, agents |> Enum.flat_map(&project_agent/1)}
  end

  def project_agents(_agents), do: {:error, :invalid_runtime_response}

  defp project_agent(agent) when is_map(agent) do
    with {:ok, id} <- identifier(fetch(agent, :task_id)),
         status when status in @statuses <- string(fetch(agent, :status)) do
      [
        %{
          "taskId" => id,
          "status" => status,
          "depth" => count(fetch(agent, :depth)) || 0,
          "messaging" => fetch(agent, :messaging) == true,
          "cancellable" => fetch(agent, :cancellable) == true
        }
        |> put("parentTaskId", optional_identifier(fetch(agent, :parent_task_id)))
        |> put("name", label(fetch(agent, :name)))
        |> put("agent", label(fetch(agent, :agent)))
        |> put("description", label(fetch(agent, :description)))
        |> put("model", label(fetch(agent, :model)))
        |> put("activity", label(fetch(agent, :activity)))
        |> put("createdAtMs", count(fetch(agent, :created_at_ms)))
        |> put("startedAtMs", count(fetch(agent, :started_at_ms)))
        |> put("completedAtMs", count(fetch(agent, :completed_at_ms)))
        |> put("updatedAtMs", count(fetch(agent, :updated_at_ms)))
        |> put("contextPercent", number(fetch(agent, :context_percent)))
        |> put("usage", usage(fetch(agent, :usage)))
      ]
    else
      _ -> []
    end
  end

  defp project_agent(_agent), do: []

  def project_transcript(task_id, transcript) when is_map(transcript) do
    with ^task_id <- fetch(transcript, :task_id),
         status when status in @statuses <- string(fetch(transcript, :status)),
         text when is_binary(text) <- fetch(transcript, :text),
         true <- String.valid?(text) and byte_size(text) <= @max_text_bytes do
      {:ok,
       %{
         "taskId" => task_id,
         "status" => status,
         "text" => text,
         "truncated" => fetch(transcript, :truncated) == true
       }}
    else
      _ -> {:error, :invalid_runtime_response}
    end
  end

  def project_transcript(_task_id, _transcript), do: {:error, :invalid_runtime_response}

  def project_delivery(task_id, delivery) when delivery in @deliveries do
    {:ok,
     %{
       "taskId" => task_id,
       "accepted" => delivery in @accepted,
       "delivery" => Atom.to_string(delivery),
       # An unknown outcome may already have been delivered; never resend it.
       "retrySafe" => delivery != :outcome_unknown
     }}
  end

  def project_delivery(_task_id, _delivery), do: {:error, :invalid_runtime_response}

  def error(:not_found),
    do: {:error, {:not_found, "Subagent not found", %{"code" => "SUBAGENT_NOT_FOUND"}}}

  def error(:not_running),
    do:
      {:error,
       {:conflict, "Subagent is not running, idle or parked", %{"code" => "SUBAGENT_NOT_ACTIVE"}}}

  def error(:not_resumable),
    do:
      {:error,
       {:conflict, "Subagent can no longer be resumed; read its transcript",
        %{"code" => "SUBAGENT_NOT_RESUMABLE"}}}

  def error(:not_messageable),
    do:
      {:error,
       {:conflict, "Subagent does not accept messages", %{"code" => "SUBAGENT_NOT_MESSAGEABLE"}}}

  def error(:queue_full),
    do:
      {:error, {:conflict, "Subagent message queue is full", %{"code" => "SUBAGENT_QUEUE_FULL"}}}

  def error(:invalid_message),
    do: NativeSessions.invalid("message must be non-empty text of at most 32 KiB")

  def error(_reason),
    do:
      {:error,
       {:unavailable, "Agent runtime unavailable", %{"code" => "AGENT_RUNTIME_UNAVAILABLE"}}}

  defp usage(usage) when is_map(usage) do
    projected =
      %{}
      |> put("tokens", count(fetch(usage, :tokens)))
      |> put("costUsd", number(fetch(usage, :cost_usd)))
      |> put("requests", count(fetch(usage, :requests)))
      |> put("input", count(fetch(usage, :input)))
      |> put("output", count(fetch(usage, :output)))

    if map_size(projected) == 0, do: nil, else: projected
  end

  defp usage(_usage), do: nil

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp identifier(value) when is_binary(value) do
    if value != "" and byte_size(value) <= @max_id_bytes and String.valid?(value) and
         not String.contains?(value, ["/", "\\", <<0>>]),
       do: {:ok, value},
       else: {:error, :invalid_identifier}
  end

  defp identifier(_value), do: {:error, :invalid_identifier}

  defp optional_identifier(value) do
    case identifier(value) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_value), do: nil

  # Display labels: valid UTF-8, single-line and bounded.
  defp label(value) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(~r/[\p{Cc}\s]+/u, " ") |> String.trim() do
        "" -> nil
        plain when byte_size(plain) <= @max_label_bytes -> plain
        plain -> truncate(plain)
      end
    end
  end

  defp label(_value), do: nil

  defp truncate(plain) do
    plain
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme
      if byte_size(next) > @max_label_bytes - 3, do: {:halt, acc <> "…"}, else: {:cont, next}
    end)
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_value), do: nil

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end

defmodule LemonControlPlane.Methods.SubagentsList do
  @moduledoc """
  Agent Hub roster: the task subagents of one session, nested children
  included, with status, persona, model, timing, activity and usage. Bounded
  display fields only — no prompts, raw paths or credentials.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SubagentSupport, as: Support

  @impl true
  def name, do: "subagents.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.session_key(params) do
      case Support.call(:subagents_list, [key]) do
        {:ok, agents} ->
          case Support.project_agents(agents) do
            {:ok, projected} ->
              {:ok, %{"sessionKey" => key, "agents" => projected, "total" => length(projected)}}

            {:error, reason} ->
              Support.error(reason)
          end

        {:error, reason} ->
          Support.error(reason)

        _other ->
          Support.error(:invalid_runtime_response)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.SubagentsTranscript do
  @moduledoc """
  Bounded visible transcript of one of the session's subagents — the same
  projection as the agent-facing `history://<task_id>`. Child output is
  untrusted text; hidden reasoning is never included.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SubagentSupport, as: Support

  @impl true
  def name, do: "subagents.transcript"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.session_key(params),
         {:ok, task_id} <- Support.task_id(params) do
      case Support.call(:subagent_transcript, [key, task_id]) do
        {:ok, transcript} ->
          case Support.project_transcript(task_id, transcript) do
            {:ok, payload} -> {:ok, payload}
            {:error, reason} -> Support.error(reason)
          end

        {:error, reason} ->
          Support.error(reason)

        _other ->
          Support.error(:invalid_runtime_response)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.SubagentsSend do
  @moduledoc """
  Operator message to one of the session's subagents, with the task tool's
  delivery semantics: steer a running child, wake an idle one, revive a parked
  one. `delivery: "outcome_unknown"` may already have been delivered and is not
  safe to resend.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SubagentSupport, as: Support
  alias LemonCore.AgentRuntime

  @impl true
  def name, do: "subagents.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.session_key(params),
         {:ok, task_id} <- Support.task_id(params),
         {:ok, message} <- Support.message(params) do
      # A registered runtime that raises or exits may have delivered before failing.
      fallback = if AgentRuntime.available?(), do: :outcome_unknown, else: {:error, :unavailable}

      case AgentRuntime.call(:subagent_send, [key, task_id, message], fallback) do
        {:ok, delivery} ->
          case Support.project_delivery(task_id, delivery) do
            {:ok, payload} -> {:ok, payload}
            {:error, _reason} -> outcome_unknown(task_id)
          end

        {:error, reason} ->
          Support.error(reason)

        _other ->
          outcome_unknown(task_id)
      end
    end
  end

  defp outcome_unknown(task_id), do: Support.project_delivery(task_id, :outcome_unknown)
end

defmodule LemonControlPlane.Methods.SubagentsCancel do
  @moduledoc """
  Cancel one of the session's subagents. Cancellation is terminal: the child
  stops and cannot be revived, and its transcript stays readable.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SubagentSupport, as: Support

  @impl true
  def name, do: "subagents.cancel"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.session_key(params),
         {:ok, task_id} <- Support.task_id(params) do
      case Support.call(:subagent_cancel, [key, task_id]) do
        :ok -> {:ok, %{"taskId" => task_id, "cancelled" => true}}
        {:error, reason} -> Support.error(reason)
        _other -> Support.error(:invalid_runtime_response)
      end
    end
  end
end
