defmodule LemonSkills.Tools.Peer do
  @moduledoc """
  Persistent A2A peer conversation and coordination tool.

  Conversations belong to the calling session: `tool/2` requires the canonical
  `:session_key` and `:agent_id`, and every context, default pointer and task it
  touches is owned by that pair. `message` resumes the session's default context
  with a peer; `new` deliberately starts and selects a fresh one. Contexts and
  tasks created for another session are refused. Remote text is always returned
  as untrusted content.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ExternalContent
  alias LemonAgent.Types.AgentTool
  alias LemonCore.A2A.{Client, Protocol}
  alias LemonCore.{A2AStore, Secrets}

  @actions ~w(list discover message new history status cancel)

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "peer",
      timeout_ms: :infinity,
      label: "A2A Peer",
      description:
        "Talk and coordinate with configured A2A agents such as Hermes. Use action=message for the peer's persistent long-running conversation; it automatically resumes the same context. Use action=new only when a separate conversation is intentional. Peer responses are external untrusted content.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" => "Peer conversation or task operation to run."
          },
          "peer_id" => %{"type" => "string", "description" => "Configured peer id."},
          "text" => %{"type" => "string", "description" => "Message or coordination request."},
          "task_id" => %{"type" => "string", "description" => "Remote A2A task id."},
          "context_id" => %{
            "type" => "string",
            "description" => "Optional explicit context for history; normally omit."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 100,
            "description" => "Maximum local history messages to return."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @spec execute(binary(), map(), reference() | nil, function() | nil, keyword()) ::
          LemonAgent.Types.AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, opts) do
    cond do
      AbortSignal.aborted?(signal) ->
        {:error, "Operation aborted"}

      owner = owner(opts) ->
        dispatch(params, owner)

      true ->
        {:error, "peer requires a session_key and agent_id in the tool context"}
    end
  end

  defp owner(opts) do
    case {opts[:agent_id], opts[:session_key]} do
      {agent_id, session_key}
      when is_binary(agent_id) and agent_id != "" and is_binary(session_key) and
             session_key != "" ->
        {agent_id, session_key}

      _ ->
        nil
    end
  end

  defp dispatch(%{"action" => "list"}, owner), do: list_peers(owner)
  defp dispatch(%{"action" => "discover"} = params, _owner), do: with_peer(params, &discover/1)

  defp dispatch(%{"action" => "message"} = params, owner),
    do: with_peer(params, &send_persistent(&1, owner, params, false))

  defp dispatch(%{"action" => "new"} = params, owner),
    do: with_peer(params, &send_persistent(&1, owner, params, true))

  defp dispatch(%{"action" => "history"} = params, owner),
    do: with_peer(params, &history(&1, owner, params))

  defp dispatch(%{"action" => "status"} = params, owner),
    do: with_peer(params, &task_action(&1, owner, params, :status))

  defp dispatch(%{"action" => "cancel"} = params, owner),
    do: with_peer(params, &task_action(&1, owner, params, :cancel))

  defp dispatch(%{"action" => action}, _owner) when is_binary(action),
    do: {:error, "unsupported peer action: #{action}"}

  defp dispatch(_, _owner), do: {:error, "missing required parameter: action"}

  defp list_peers(owner) do
    peers =
      peer_config()
      |> Enum.map(fn {id, peer} ->
        context = A2AStore.default_context(id, owner)

        %{
          id: id,
          url: peer.url,
          capabilities: peer.capabilities,
          default_context_id: context && context.id,
          turn_count: context && context.turn_count
        }
      end)
      |> Enum.sort_by(& &1.id)

    result(%{peers: peers})
  end

  defp discover(peer) do
    case Client.agent_card(peer.url, client_opts(peer)) do
      {:ok, card} -> result(%{peer_id: peer.id, agent_card: card})
      {:error, reason} -> request_error(reason)
    end
  end

  defp send_persistent(peer, owner, params, new?) do
    with {:ok, text} <- required_string(params, "text"),
         {:ok, context} <- context(peer.id, owner, new?),
         message = Protocol.message("ROLE_USER", text, context_id: context.id),
         {:ok, response} <- Client.send_message(peer.url, message, client_opts(peer)),
         {:ok, remote} <- Protocol.unwrap_task(response),
         {:ok, payload} <- persist_response(peer.id, owner, context.id, message, remote) do
      result(payload)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> request_error(reason)
    end
  end

  defp history(peer, owner, params) do
    context =
      case params["context_id"] do
        id when is_binary(id) and id != "" -> A2AStore.owned_context(peer.id, owner, id)
        _ -> A2AStore.default_context(peer.id, owner)
      end

    cond do
      context ->
        limit = normalize_limit(params["limit"])

        case A2AStore.history(peer.id, context.id, limit: limit, direction: :outbound) do
          {:ok, messages} ->
            result(%{
              peer_id: peer.id,
              context:
                Map.take(context, [:id, :peer_id, :turn_count, :created_at_ms, :updated_at_ms]),
              messages: messages
            })

          {:error, _reason} ->
            {:error, "peer history is temporarily unavailable"}
        end

      is_binary(params["context_id"]) and params["context_id"] != "" ->
        {:error, "unknown context_id for this session"}

      true ->
        {:error, "peer has no conversation yet"}
    end
  end

  defp task_action(peer, owner, params, action) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, owned} <- owned_task(peer.id, owner, task_id),
         {:ok, response} <- call_task(peer, task_id, action),
         {:ok, remote} <- Protocol.unwrap_task(response) do
      _ = persist_remote_task(peer.id, owner, owned.context_id, Map.put(remote, "id", task_id))
      result(%{peer_id: peer.id, task: remote})
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> request_error(reason)
    end
  end

  defp owned_task(peer_id, owner, task_id) do
    case A2AStore.owned_task(peer_id, owner, task_id) do
      nil -> {:error, "unknown task_id for this session"}
      task -> {:ok, task}
    end
  end

  defp call_task(peer, task_id, :status),
    do: Client.get_task(peer.url, task_id, client_opts(peer))

  defp call_task(peer, task_id, :cancel),
    do: Client.cancel_task(peer.url, task_id, client_opts(peer))

  defp context(peer_id, owner, true), do: A2AStore.new_owned_context(peer_id, owner)

  defp context(peer_id, owner, false) do
    case A2AStore.default_context(peer_id, owner) do
      nil -> context(peer_id, owner, true)
      context -> {:ok, context}
    end
  end

  defp persist_response(peer_id, owner, context_id, sent, remote) do
    task_id = remote["id"] || remote["taskId"]

    {:ok, _} =
      A2AStore.append_message(%{
        id: sent["messageId"],
        direction: :outbound,
        peer_id: peer_id,
        context_id: context_id,
        task_id: task_id,
        role: "ROLE_USER",
        text: elem(Protocol.text(sent), 1)
      })

    answer = remote_text(remote)

    if is_binary(answer) and answer != "" do
      {:ok, _} =
        A2AStore.append_message(%{
          direction: :outbound,
          peer_id: peer_id,
          context_id: context_id,
          task_id: task_id,
          role: "ROLE_AGENT",
          text: answer
        })
    end

    {:ok, context} = A2AStore.increment_turn(:outbound, peer_id, context_id)
    _ = persist_remote_task(peer_id, owner, context_id, remote)

    {:ok,
     %{
       peer_id: peer_id,
       context_id: context_id,
       turn_count: context.turn_count,
       task: remote,
       answer: answer
     }}
  end

  # The task is bound to the local context it was created in; a remote-supplied
  # `contextId` never re-homes it.
  defp persist_remote_task(peer_id, owner, context_id, remote) do
    id = remote["id"] || remote["taskId"]

    if is_binary(id) do
      A2AStore.put_owned_task(owner, %{
        id: id,
        peer_id: peer_id,
        context_id: context_id,
        state: get_in(remote, ["status", "state"]),
        answer: remote_text(remote)
      })
    else
      :ok
    end
  end

  defp remote_text(%{"artifacts" => artifacts} = task) when is_list(artifacts) do
    Enum.find_value(artifacts, &text_or_nil/1) || status_text(task)
  end

  defp remote_text(%{"status" => _} = task), do: status_text(task)
  defp remote_text(%{"parts" => _} = message), do: text_or_nil(message)
  defp remote_text(_), do: nil

  defp status_text(%{"status" => %{"message" => message}}), do: text_or_nil(message)
  defp status_text(_), do: nil

  defp text_or_nil(message) do
    case Protocol.text(message) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp with_peer(params, fun) do
    with {:ok, peer_id} <- required_string(params, "peer_id"),
         %{} = peer <- Map.get(peer_config(), peer_id),
         true <- is_binary(peer.url) and peer.url != "" do
      fun.(peer)
    else
      nil -> {:error, "unknown peer_id"}
      false -> {:error, "peer has no configured URL"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp peer_config do
    case Application.get_env(:lemon_skills, :a2a_peers) do
      peers when is_map(peers) -> peers
      _ -> LemonCore.Config.load().gateway |> Map.get(:a2a, %{}) |> Map.get(:peers, %{})
    end
  end

  defp client_opts(peer) do
    secret_name = peer.outbound_token_secret || peer.token_secret
    token = if is_binary(secret_name), do: Secrets.fetch_value(secret_name), else: nil
    [token: token, timeout: peer.timeout_ms || 300_000]
  end

  defp result(payload), do: ExternalContent.untrusted_json_result(stringify_keys(payload))

  defp request_error({:http_error, status}),
    do: {:error, "peer HTTP request failed with status #{status}"}

  defp request_error({:remote_error, error}), do: result(%{peer_error: error})
  defp request_error(reason), do: {:error, "peer request failed: #{inspect(reason)}"}

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _ -> {:error, "missing required parameter: #{key}"}
    end
  end

  defp normalize_limit(value) when is_integer(value), do: value |> min(100) |> max(1)
  defp normalize_limit(_), do: 50

  defp stringify_keys(value) when is_struct(value),
    do: value |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value
end
