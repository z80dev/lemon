defmodule LemonControlPlane.Methods.MemorySupport do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{JSONPayload, NodeRegistry, ProfileStore}
  alias LemonMemory.{ContextScope, Lifecycle, Safety}

  @timeout_ms 30_000
  @max_result_bytes 256 * 1_024
  @fields ~w(profileId query limit cursor id text kind confirm memoryScope memoryContextKey)
  @kinds ~w(user memory run learned_source project_learning)

  def handle(operation, params, ctx) when is_map(params) do
    with :ok <- validate(operation, params),
         :ok <- validate_scope(params),
         {:ok, profile} <- ProfileStore.get(params["profileId"]),
         {:ok, payload} <- execute(operation, profile, Map.take(params, @fields), ctx),
         {:ok, projection} <- project(operation, payload),
         {:ok, projection} <- scoped_projection(params, payload, projection) do
      {:ok, projection}
    else
      {:rpc_error, error} -> {:error, error}
      {:error, reason} -> error(reason)
    end
  rescue
    _ -> error(:memory_unavailable)
  catch
    :exit, _ -> error(:memory_unavailable)
  end

  def handle(_operation, _params, _ctx), do: error(:invalid_params)

  defp validate_scope(params) do
    case ContextScope.selection(params) do
      {:ok, _selection} -> :ok
      _ -> {:error, :invalid_params}
    end
  end

  defp scoped_projection(params, payload, projection) do
    case params["memoryScope"] do
      nil ->
        {:ok, projection}

      scope ->
        key = if scope == "private", do: params["memoryContextKey"], else: nil

        if payload["memoryScope"] == scope and Map.has_key?(payload, "memoryContextKey") and
             payload["memoryContextKey"] == key do
          {:ok, Map.merge(projection, %{"memoryScope" => scope, "memoryContextKey" => key})}
        else
          # An older worker ignoring scope arguments cannot attest a scoped result.
          {:error, :memory_unavailable}
        end
    end
  end

  defp validate(operation, params) do
    cond do
      not bounded_string?(params["profileId"], 64) ->
        {:error, :invalid_params}

      Map.has_key?(params, "limit") and
          not (is_integer(params["limit"]) and params["limit"] in 1..50) ->
        {:error, :invalid_params}

      Map.has_key?(params, "query") and not Lifecycle.valid_profile_query?(params["query"]) ->
        {:error, :invalid_params}

      Map.has_key?(params, "cursor") and not bounded_string?(params["cursor"], 512) ->
        {:error, :invalid_params}

      operation == "search" and
          (not Lifecycle.valid_profile_query?(params["query"]) or
             String.trim(params["query"]) == "") ->
        {:error, :invalid_params}

      operation in ["get", "delete"] and not bounded_string?(params["id"], 256) ->
        {:error, :invalid_params}

      operation == "delete" and params["confirm"] != params["id"] ->
        {:error, :confirmation_required}

      operation == "add" and not bounded_string?(params["text"], 4_096) ->
        {:error, :invalid_params}

      operation == "add" and Map.get(params, "kind", "memory") not in ["memory", "user"] ->
        {:error, :invalid_params}

      true ->
        :ok
    end
  end

  defp bounded_string?(text, max),
    do: bounded_text?(text, max) and String.trim(text) != ""

  defp bounded_text?(text, max) when is_binary(text),
    do: byte_size(text) <= max and String.valid?(text) and not String.contains?(text, <<0>>)

  defp bounded_text?(_text, _max), do: false

  defp execute(operation, %{"node" => node} = profile, args, _ctx)
       when is_binary(node) and node != "local" do
    with {:ok, _stats} <- JSONPayload.validate(args, max_bytes: 8_192),
         {:ok, resolved} <- NodeRegistry.resolve(node),
         :ok <- scoped_worker_capability(resolved, operation, args),
         {:ok, invoke_id} <-
           NodeRegistry.invoke_node(resolved.id, "memory." <> operation, args,
             expected_pid: resolved.pid,
             recipient: self(),
             timeout_ms: @timeout_ms,
             max_payload_bytes: @max_result_bytes
           ) do
      receive do
        {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true, "payload" => payload}}} ->
          {:ok, payload}

        {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => false, "error" => reason}}} ->
          remote_error(reason)

        {:lemon_node_result, ^invoke_id, _result} ->
          remote_failure(operation, profile["id"], invoke_id)
      after
        @timeout_ms + 1_000 ->
          NodeRegistry.cancel(invoke_id, :timeout)
          remote_failure(operation, profile["id"], invoke_id)
      end
    else
      {:error, _reason} -> {:error, :node_unavailable}
    end
  end

  defp execute(operation, profile, args, ctx) do
    LemonSkills.ProfileMemory.execute(
      operation,
      profile["id"],
      args,
      Map.get(ctx, :memory_opts, [])
    )
  end

  # A post-write echo alone is insufficient: old workers would already have
  # written shared files. Check before dispatch and bind the exact checked connection.
  defp scoped_worker_capability(_node, _operation, %{"memoryScope" => nil}),
    do: {:error, :invalid_memory_scope}

  defp scoped_worker_capability(node, operation, args) do
    if Map.has_key?(args, "memoryScope") do
      capabilities = Map.get(node.metadata, :capabilities, Map.get(node.metadata, "capabilities"))
      descriptor = if is_map(capabilities), do: Map.get(capabilities, "memory." <> operation)

      if match?(%{"version" => 1, "contextVersion" => 1}, descriptor),
        do: :ok,
        else: {:error, :unsupported_memory_scope}
    else
      :ok
    end
  end

  defp remote_error("not_found"), do: {:error, :not_found}
  defp remote_error("profile_mismatch"), do: {:error, :not_found}
  defp remote_error("confirmation_required"), do: {:error, :confirmation_required}
  defp remote_error("stale"), do: {:error, :stale}
  defp remote_error("confirmation_mismatch"), do: {:error, :stale}

  defp remote_error(reason)
       when reason in [
              "invalid_params",
              "invalid_id",
              "invalid_cursor",
              "invalid_query",
              "invalid_limit",
              "invalid_kind",
              "invalid_text",
              "unsafe_text",
              "invalid_document_id",
              "capacity_exceeded",
              "empty_text",
              "unproven_context",
              "invalid_memory_scope"
            ],
       do: {:error, :invalid_params}

  defp remote_error(_reason), do: {:error, :memory_unavailable}

  defp remote_failure(operation, profile_id, invoke_id) when operation in ["add", "delete"] do
    {:rpc_error,
     Errors.error(:unavailable, "Memory mutation outcome is unknown", %{
       "code" => "MEMORY_OUTCOME_UNKNOWN",
       "profileId" => profile_id,
       "invokeId" => invoke_id,
       "retrySafe" => false
     })}
  end

  defp remote_failure(_operation, _profile_id, _invoke_id), do: {:error, :node_unavailable}

  # Re-project worker replies: only the documented bounded fields cross the operator boundary.
  defp project(operation, payload) when operation in ["list", "search"] and is_map(payload) do
    with items when is_list(items) and length(items) <= 50 <- payload["items"],
         cursor <- payload["nextCursor"],
         true <- is_nil(cursor) or bounded_string?(cursor, 512),
         {:ok, items} <- project_items(items) do
      {:ok, %{"items" => items, "nextCursor" => cursor}}
    else
      _ -> {:error, :memory_unavailable}
    end
  end

  defp project(operation, %{"item" => item}) when operation in ["get", "add"] do
    with {:ok, item} <- project_item(item), do: {:ok, %{"item" => item}}
  end

  defp project("delete", %{"deleted" => true, "id" => id}) do
    if bounded_string?(id, 256),
      do: {:ok, %{"deleted" => true, "id" => id}},
      else: {:error, :memory_unavailable}
  end

  defp project(_operation, _payload), do: {:error, :memory_unavailable}

  defp project_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case project_item(item) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp project_item(item) when is_map(item) do
    with true <- bounded_string?(item["id"], 256),
         true <- item["kind"] in @kinds,
         true <- item["source"] in ["workspace", "durable"],
         text when is_binary(text) <- item["text"],
         true <- String.valid?(text),
         true <- valid_timestamp?(item["createdAtMs"]),
         true <- valid_timestamp?(item["updatedAtMs"]) do
      {text, _redactions} = Safety.redact_for_operator(text, max_bytes: 2_045)
      {:ok, item |> Map.take(~w(id kind source createdAtMs updatedAtMs)) |> Map.put("text", text)}
    else
      _ -> {:error, :memory_unavailable}
    end
  end

  defp project_item(_item), do: {:error, :memory_unavailable}
  defp valid_timestamp?(value), do: is_integer(value) and value >= 0

  defp error(:not_found), do: {:error, Errors.not_found("Profile or memory item not found")}
  defp error(:profile_mismatch), do: error(:not_found)

  defp error(:confirmation_required),
    do: {:error, Errors.invalid_request("confirm must equal the exact memory id")}

  defp error(reason)
       when reason in [
              :invalid_params,
              :invalid_id,
              :invalid_cursor,
              :invalid_query,
              :invalid_limit,
              :invalid_kind,
              :invalid_text,
              :unsafe_text,
              :invalid_document_id,
              :capacity_exceeded,
              :empty_text,
              :unproven_context,
              :invalid_memory_scope
            ],
       do: {:error, Errors.invalid_request("Memory parameters or content are invalid")}

  defp error(reason) when reason in [:stale, :confirmation_mismatch],
    do: {:error, Errors.error(:conflict, "Memory item changed; read it again before deleting")}

  defp error(:node_unavailable), do: {:error, Errors.unavailable("Profile node is unavailable")}
  defp error(_reason), do: {:error, Errors.unavailable("Profile memory is unavailable")}
end

defmodule LemonControlPlane.Methods.MemoryList do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "memory.list"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.MemorySupport.handle("list", params, ctx)
end

defmodule LemonControlPlane.Methods.MemorySearch do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "memory.search"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx),
    do: LemonControlPlane.Methods.MemorySupport.handle("search", params, ctx)
end

defmodule LemonControlPlane.Methods.MemoryGet do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "memory.get"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.MemorySupport.handle("get", params, ctx)
end

defmodule LemonControlPlane.Methods.MemoryAdd do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "memory.add"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.MemorySupport.handle("add", params, ctx)
end

defmodule LemonControlPlane.Methods.MemoryDelete do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "memory.delete"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx),
    do: LemonControlPlane.Methods.MemorySupport.handle("delete", params, ctx)
end
