defmodule LemonCore.InvocationProof do
  @moduledoc """
  Data contract for a factory-attested, run-bound core MCP proof header.

  Authentication belongs to the admitting operator boundary. `validate/3` binds
  the descriptor to the actual execution server/header and fixed run ID; it does
  not grant authority by itself. `comparison_servers/1` changes only a temporary
  comparison projection, never the actual transport configuration.
  """

  alias LemonCore.{MapHelpers, RunRequest}

  @header "X-Lemon-Bot-Invocation"
  @namespace "lemon_bot/invocations/"
  @fields ~w(runId serverName serverUrl headerName secretName)

  def validate(descriptor, run_id, servers) when is_map(descriptor) do
    if map_size(descriptor) == length(@fields) and Enum.all?(@fields, &Map.has_key?(descriptor, &1)) do
      record = %{
        run_id: descriptor["runId"], server_name: descriptor["serverName"],
        server_url: descriptor["serverUrl"], header_name: descriptor["headerName"],
        secret_name: descriptor["secretName"]
      }

      if bound_record?(record, run_id, servers),
        do: {:ok, record},
        else: {:error, :invalid_invocation_proof}
    else
      {:error, :invalid_invocation_proof}
    end
  end

  def validate(_, _, _), do: {:error, :invalid_invocation_proof}

  @doc """
  Validate and attach execution context after the owning admission boundary has
  authenticated the projection. This pure factory does not authenticate callers
  or authorize shared memory; public RPCs must do that before calling it.
  """
  def attach_execution_context(%{run_id: run_id} = request, params) when is_map(params) do
    meta = Map.get(request, :meta, %{})
    shared_grant = Map.get(params, "sharedMemoryGrant", false)

    with true <- is_map(meta),
         :ok <- RunRequest.validate_invocation_context_key(run_id),
         true <- not Map.has_key?(params, "runId") or params["runId"] == run_id,
         {:ok, invocation_key} <- optional_context_key(params, "invocationContextKey"),
         {:ok, memory_key} <- optional_context_key(params, "memoryContextKey"),
         true <- is_nil(memory_key) or not is_nil(invocation_key),
         true <- is_boolean(shared_grant),
         true <- not shared_grant or (not is_nil(invocation_key) and not is_nil(memory_key)),
         {:ok, proof} <- projected_proof(params, run_id, meta, invocation_key, memory_key) do
      meta =
        if is_nil(invocation_key) do
          meta
        else
          meta |> Map.put(:invocation_context_key, invocation_key) |> Map.put_new(:mcp_servers, [])
        end

      meta =
        if is_nil(memory_key) do
          meta
        else
          meta
          |> Map.put(:memory_context_key, memory_key)
          |> Map.put(:memory_context_verified, true)
          |> Map.put(:shared_memory_grant, shared_grant)
        end

      meta =
        if is_nil(proof) do
          meta
        else
          meta |> Map.put(:invocation_proof, proof) |> Map.put(:invocation_proof_verified, true)
        end

      {:ok, Map.put(request, :meta, meta)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_invocation_context}
    end
  end

  def attach_execution_context(_, _), do: {:error, :invalid_invocation_context}

  defp optional_context_key(params, field) do
    case Map.fetch(params, field) do
      :error -> {:ok, nil}
      {:ok, key} ->
        case RunRequest.validate_invocation_context_key(key) do
          :ok -> {:ok, key}
          _ -> {:error, :invalid_invocation_context}
        end
    end
  end

  defp projected_proof(params, run_id, meta, invocation_key, memory_key) do
    case Map.fetch(params, "invocationProof") do
      :error -> {:ok, nil}
      {:ok, descriptor} ->
        if params["runId"] == run_id and not is_nil(invocation_key) and not is_nil(memory_key),
          do: validate(descriptor, run_id, Map.get(meta, :mcp_servers)),
          else: {:error, :invalid_invocation_proof}
    end
  end

  @doc "Project only the exact attested proof value out of execution-context comparisons."
  def comparison_servers(%{run_id: run_id, meta: meta}) when is_map(meta) do
    servers = Map.get(meta, :mcp_servers)
    proof = Map.get(meta, :invocation_proof)

    trusted = Map.get(meta, :invocation_proof_verified) == true and
      Map.get(meta, :memory_context_verified) == true and
      RunRequest.validate_invocation_context_key(Map.get(meta, :invocation_context_key)) == :ok and
      RunRequest.validate_invocation_context_key(Map.get(meta, :memory_context_key)) == :ok

    if trusted and bound_record?(proof, run_id, servers) do
      Enum.map(servers, fn server ->
        if selected_server?(server, proof) do
          headers = MapHelpers.get_key(server, :headers)
          # A non-JSON marker cannot collide with an unattested header string.
          headers = Map.put(headers, @header, {:factory_owned_invocation_proof, @header})
          put_headers(server, headers)
        else
          server
        end
      end)
    else
      servers
    end
  end

  def comparison_servers(%{meta: meta}) when is_map(meta), do: Map.get(meta, :mcp_servers)
  def comparison_servers(_), do: nil

  defp bound_record?(%{run_id: run_id, server_name: name, server_url: url,
                      header_name: @header, secret_name: secret} = proof, run_id, servers)
       when is_binary(run_id) and is_binary(name) and name != "" and
              is_binary(url) and url != "" and is_binary(secret) and is_list(servers) do
    with :ok <- RunRequest.validate_invocation_context_key(run_id),
         true <- secret == @namespace <> run_id do
      matches = Enum.filter(servers, &selected_server?(&1, proof))
      case matches do
        [server] ->
          case MapHelpers.get_key(server, :headers) do
            headers when is_map(headers) -> Map.get(headers, @header) == "${LEMON_SECRET:#{secret}}"
            _ -> false
          end
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp bound_record?(_, _, _), do: false

  defp selected_server?(server, %{server_name: name, server_url: url}) when is_map(server),
    do: MapHelpers.get_key(server, :name) == name and MapHelpers.get_key(server, :url) == url
  defp selected_server?(_, _), do: false

  defp put_headers(server, headers) do
    if Map.has_key?(server, :headers),
      do: Map.put(server, :headers, headers),
      else: Map.put(server, "headers", headers)
  end
end
