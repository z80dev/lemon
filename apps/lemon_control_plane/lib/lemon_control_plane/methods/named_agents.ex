defmodule LemonControlPlane.Methods.NamedAgents do
  @moduledoc """
  Operator-only wire boundary for durable named identities and correlated messages.

  Private scopes require administrative authority. Transport registration and
  completion always use the authenticated connection PID, never a caller value.
  Unknown mutation outcomes are explicitly unsafe to retry.
  """

  alias LemonCore.AgentMessaging

  def handle(action, params, ctx, required_scope) do
    params = params || %{}

    with :ok <- authorize(ctx, required_scope),
         :ok <- validate(action, params),
         {:ok, scope} <- scope(params, ctx) do
      invoke(action, params, ctx, scope) |> project(action)
    end
  rescue
    _ -> error(:outcome_unknown)
  catch
    :exit, _ -> error(:outcome_unknown)
    :throw, _ -> error(:outcome_unknown)
  end

  defp authorize(%{auth: %{role: :operator, scopes: scopes}}, required) do
    if required in scopes or :admin in scopes, do: :ok, else: error(:forbidden)
  end

  defp authorize(_, _), do: error(:forbidden)

  defp scope(params, ctx) do
    scope = Map.get(params, "scope", "operator")

    if scope == "operator" or :admin in ctx.auth.scopes,
      do: {:ok, scope},
      else: error(:forbidden)
  end

  defp validate(action, params) when is_map(params) do
    fields = fields(action)
    allowed = Enum.map(fields, &elem(&1, 0))

    if Enum.all?(Map.keys(params), &(&1 in allowed)) and
         Enum.all?(fields, fn {key, type, required} ->
           if Map.has_key?(params, key),
             do: valid?(params[key], type),
             else: not required
         end),
       do: :ok,
       else: error(:invalid_arguments)
  end

  defp validate(_, _), do: error(:invalid_arguments)

  defp fields(:list),
    do: [
      {"scope", {:text, 256}, false},
      {"limit", :limit, false},
      {"query", {:optional_text, 256}, false}
    ]

  defp fields(:rename),
    do: [{"scope", {:text, 256}, false}, {"id", {:text, 1024}, true}, {"name", :name, true}]

  defp fields(:register),
    do: [
      {"scope", {:text, 256}, true},
      {"id", :bot_id, true},
      {"name", :name, false},
      {"label", {:optional_text, 256}, false},
      {"metadata", :metadata, true}
    ]

  defp fields(:unregister), do: [{"scope", {:text, 256}, true}, {"id", :bot_id, true}]

  defp fields(:send),
    do: [
      {"scope", {:text, 256}, false},
      {"sourceId", {:text, 1024}, true},
      {"target", {:text, 1024}, true},
      {"text", {:text, 32_768}, true},
      {"messageId", {:text, 256}, true}
    ]

  defp fields(:get),
    do: [
      {"scope", {:text, 256}, false},
      {"sourceId", {:text, 1024}, true},
      {"messageId", {:text, 256}, true}
    ]

  defp fields(:complete),
    do: [
      {"messageId", {:text, 256}, true},
      {"status", :status, true},
      {"runId", {:text, 256}, false},
      {"response", {:optional_text, 32_768}, false},
      {"error", :error, false}
    ]

  defp valid?(value, {:text, max}),
    do:
      is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max and
        String.valid?(value)

  defp valid?(value, {:optional_text, max}),
    do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  defp valid?(value, :limit), do: is_integer(value) and value in 1..200
  defp valid?(nil, :name), do: true

  defp valid?(value, :name),
    do:
      is_binary(value) and byte_size(value) <= 65 and String.valid?(value) and
        Regex.match?(~r/^@?[a-zA-Z][a-zA-Z0-9_-]{0,63}$/, value)

  defp valid?(value, :bot_id),
    do: valid?(value, {:text, 1024}) and String.starts_with?(value, "bot://")

  defp valid?(value, :status), do: value in ["accepted", "completed", "failed", "outcome_unknown"]

  defp valid?(value, :error),
    do:
      value in [
        "invalid_arguments",
        "invalid_message",
        "not_found",
        "self_send",
        "message_id_conflict",
        "offline",
        "forbidden",
        "unavailable",
        "unsupported",
        "outcome_unknown",
        "failed"
      ]

  defp valid?(value, :metadata) when is_map(value) do
    map_size(value) <= 16 and
      Enum.all?(value, fn {key, item} ->
        valid?(key, {:text, 64}) and valid?(item, {:text, 1024})
      end)
  end

  defp valid?(_, _), do: false

  defp invoke(:list, p, _ctx, scope),
    do:
      AgentMessaging.list(scope, limit: Map.get(p, "limit", 100), query: Map.get(p, "query", ""))

  defp invoke(:rename, p, _ctx, scope), do: AgentMessaging.rename(scope, p["id"], p["name"])

  defp invoke(:send, p, ctx, scope) do
    with {:ok, pid} <- connection(ctx) do
      AgentMessaging.send(scope, p["sourceId"], p["target"], p["text"],
        message_id: p["messageId"],
        conn_pid: pid
      )
    end
  end

  defp invoke(:get, p, _ctx, scope), do: AgentMessaging.get(scope, p["sourceId"], p["messageId"])

  defp invoke(:register, p, ctx, scope) do
    with {:ok, pid} <- connection(ctx) do
      attrs = %{id: p["id"], kind: :bot, metadata: p["metadata"]}

      attrs =
        Enum.reduce([{"name", :name}, {"label", :label}], attrs, fn {wire, key}, acc ->
          if Map.has_key?(p, wire), do: Map.put(acc, key, p[wire]), else: acc
        end)

      AgentMessaging.register_external(scope, attrs, pid)
    end
  end

  defp invoke(:unregister, p, ctx, scope) do
    with {:ok, pid} <- connection(ctx),
         :ok <- AgentMessaging.unregister_external(scope, p["id"], pid) do
      {:ok, %{"removed" => true, "id" => p["id"]}}
    end
  end

  defp invoke(:complete, p, ctx, _scope) do
    with {:ok, pid} <- connection(ctx) do
      status =
        case p["status"] do
          "accepted" -> :accepted
          "completed" -> :completed
          "failed" -> :failed
          "outcome_unknown" -> :outcome_unknown
        end

      completion = %{status: status}

      completion =
        Enum.reduce(
          [{"runId", :run_id}, {"response", :response}, {"error", :error}],
          completion,
          fn {wire, key}, acc ->
            if Map.has_key?(p, wire), do: Map.put(acc, key, p[wire]), else: acc
          end
        )

      AgentMessaging.complete_external(pid, p["messageId"], completion)
    end
  end

  defp connection(%{conn_pid: pid}) when is_pid(pid), do: {:ok, pid}
  defp connection(_), do: {:error, :forbidden}

  defp project({:ok, entries}, :list), do: {:ok, %{"agents" => Enum.map(entries, &identity/1)}}

  defp project({:ok, entry}, action) when action in [:rename, :register],
    do: {:ok, %{"agent" => identity(entry)}}

  defp project({:ok, receipt}, action) when action in [:send, :get, :complete],
    do: {:ok, receipt(receipt)}

  defp project({:ok, result}, :unregister), do: {:ok, result}
  defp project({:error, reason}, _), do: error(reason)
  defp project(_, _), do: error(:outcome_unknown)

  def identity(entry) do
    project_fields(entry, [
      {:id, "id"},
      {:name, "name"},
      {:kind, "kind"},
      {:session_key, "sessionKey"},
      {:label, "label"},
      {:status, "status"}
    ])
  end

  def receipt(entry) do
    project_fields(entry, [
      {:message_id, "messageId"},
      {:source_id, "sourceId"},
      {:target_id, "targetId"},
      {:status, "status"},
      {:run_id, "runId"},
      {:response, "response"}
    ])
  end

  defp project_fields(entry, fields) do
    Enum.reduce(fields, %{}, fn {key, wire}, acc ->
      if Map.has_key?(entry, key) do
        value = Map.get(entry, key)
        value = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value
        Map.put(acc, wire, value)
      else
        acc
      end
    end)
  end

  defp error(reason) do
    {code, category, message} =
      case reason do
        :forbidden ->
          {:forbidden, "forbidden", "Named agent access denied"}

        :not_found ->
          {:not_found, "not_found", "Named agent or message not found"}

        :offline ->
          {:unavailable, "offline", "Named agent is offline"}

        :unsupported ->
          {:unavailable, "unsupported", "Named agent messaging is unsupported"}

        :unavailable ->
          {:unavailable, "unavailable", "Named agent messaging is unavailable"}

        :query_failed ->
          {:unavailable, "query_failed", "Named agent query is unavailable"}

        :submission_failed ->
          {:unavailable, "submission_failed", "Named agent submission was rejected"}

        reason
        when reason in [
               :invalid_arguments,
               :invalid_message,
               :invalid_name,
               :invalid_scope,
               :invalid_id,
               :invalid_attrs,
               :invalid_label,
               :invalid_metadata,
               :invalid_options,
               :invalid_session,
               :invalid_completion
             ] ->
          {:invalid_request, "invalid_arguments", "Invalid named agent parameters"}

        reason
        when reason in [
               :scope_full,
               :identity_busy,
               :session_busy,
               :store_unavailable,
               :invalid_identity_state,
               :context_unavailable
             ] ->
          {:unavailable, Atom.to_string(reason), "Named agent identity is unavailable"}

        reason
        when reason in [
               :name_taken,
               :name_conflict,
               :already_registered,
               :message_id_conflict,
               :self_send,
               :completion_conflict,
               :receipt_conflict
             ] ->
          {:conflict, Atom.to_string(reason),
           "Named agent operation conflicts with existing state"}

        _ ->
          {:unavailable, "outcome_unknown", "Named agent operation outcome is unknown"}
      end

    unknown? = category == "outcome_unknown"

    {:error,
     {code, message,
      %{"reason" => category, "retrySafe" => not unknown?, "mutationMayHaveApplied" => unknown?}}}
  end
end

defmodule LemonControlPlane.Methods.AgentIdentityList do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.identity.list"
  def scopes, do: [:read]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:list, params, ctx, :read)
end

defmodule LemonControlPlane.Methods.AgentIdentityRename do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.identity.rename"
  def scopes, do: [:write]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:rename, params, ctx, :write)
end

defmodule LemonControlPlane.Methods.AgentIdentityRegister do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.identity.register"
  def scopes, do: [:admin]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:register, params, ctx, :admin)
end

defmodule LemonControlPlane.Methods.AgentIdentityUnregister do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.identity.unregister"
  def scopes, do: [:admin]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:unregister, params, ctx, :admin)
end

defmodule LemonControlPlane.Methods.AgentMessageSend do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.message.send"
  def scopes, do: [:write]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:send, params, ctx, :write)
end

defmodule LemonControlPlane.Methods.AgentMessageGet do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.message.get"
  def scopes, do: [:read]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:get, params, ctx, :read)
end

defmodule LemonControlPlane.Methods.AgentMessageComplete do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  def name, do: "agent.message.complete"
  def scopes, do: [:admin]

  def handle(params, ctx),
    do: LemonControlPlane.Methods.NamedAgents.handle(:complete, params, ctx, :admin)
end
