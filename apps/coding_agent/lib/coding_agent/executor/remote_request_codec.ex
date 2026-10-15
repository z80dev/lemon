defmodule CodingAgent.Executor.RemoteRequestCodec do
  @moduledoc """
  Builds the JSON boundary for a named-node coding-agent invocation.

  Only execution request data crosses the boundary. Runtime executor options,
  resolved provider credentials, callbacks, and source-node process state are
  intentionally excluded. For delegated agent requests, `remote_cwd_explicit`
  distinguishes an explicit destination path from the source router's default
  cwd; omitted remote cwd is encoded as `nil` for destination-local resolution.
  """

  alias LemonCore.{ExecutionContext, ResumeToken, ToolPolicy}
  alias LemonGateway.ExecutionRequest

  @version 2

  @execution_meta_keys ~w(model thinking_level system_prompt profile_id profile_instructions
                          mcp_servers invocation_mcp_servers invocation_context_key
                          native_lineage_handle native_lineage_run_id
                          agent_id async_followups resume_source acp_session_id
                          acp_mcp_session_id acp_client_terminal acp_client_elicitation_form
                          acp_client_fs_read_text_file acp_client_fs_write_text_file)a

  @private_meta_aliases [
    {:invocation_context_key,
     ["invocation_context_key", "invocationContextKey", :invocationContextKey]},
    {:memory_context_key, ["memory_context_key", "memoryContextKey", :memoryContextKey]},
    {:memory_context_verified,
     ["memory_context_verified", "memoryContextVerified", :memoryContextVerified]},
    {:shared_memory_grant, ["shared_memory_grant", "sharedMemoryGrant", :sharedMemoryGrant]},
    {:invocation_proof_verified,
     ["invocation_proof_verified", "invocationProofVerified", :invocationProofVerified]},
    {:invocation_proof, ["invocation_proof", "invocationProof", :invocationProof]},
    {:native_lineage_handle,
     ["native_lineage_handle", "nativeLineageHandle", :nativeLineageHandle]},
    {:native_lineage_run_id, ["native_lineage_run_id", "nativeLineageRunId", :nativeLineageRunId]}
  ]

  @proof_meta_aliases [
    {:run_id, ["run_id", "runId", :runId]},
    {:server_name, ["server_name", "serverName", :serverName]},
    {:server_url, ["server_url", "serverUrl", :serverUrl]},
    {:header_name, ["header_name", "headerName", :headerName]},
    {:secret_name, ["secret_name", "secretName", :secretName]}
  ]

  @doc false
  def normalize_meta(meta) when is_map(meta) do
    Enum.reduce(@execution_meta_keys, meta, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.fetch(acc, key) do
        {:ok, _value} ->
          Map.delete(acc, string_key)

        :error ->
          case Map.fetch(acc, string_key) do
            {:ok, value} -> acc |> Map.delete(string_key) |> Map.put(key, value)
            :error -> acc
          end
      end
    end)
  end

  def normalize_meta(_), do: %{}

  @spec encode(ExecutionRequest.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def encode(request, opts \\ [])

  def encode(%ExecutionRequest{} = request, opts) do
    cwd = remote_cwd(request)
    native_images = if is_nil(request.images), do: [], else: request.images

    with {:ok, source_meta} <- normalize_source_meta(request.meta),
         {:ok, images} <- LemonAi.ImageInputs.encode(native_images),
         {:ok, remote_context} <- ExecutionContext.for_remote(request.execution_context, cwd),
         :ok <- validate_context_run_id(remote_context, request.run_id),
         {:ok, requested_policy} <-
           ToolPolicy.resolve(request.tool_policy, remote_context.tool_policy),
         {:ok, policy} <- ToolPolicy.restrict(remote_context.tool_policy, requested_policy),
         {:ok, remote_context} <-
           ExecutionContext.validate(%{remote_context | tool_policy: policy}),
         {:ok, encoded_context} <- ExecutionContext.encode(remote_context) do
      payload = %{
        "version" => @version,
        "runId" => request.run_id,
        "sessionKey" => request.session_key,
        "prompt" => request.prompt,
        "images" => images,
        "cwd" => cwd,
        "resume" => encode_resume(request.resume),
        "lane" => encode_atom(request.lane),
        "toolPolicy" => ToolPolicy.to_map(policy),
        "executionContext" => encoded_context,
        # Cwd routing hints are consumed above, not execution metadata. In particular
        # an unused controller path must not survive through a false explicit flag.
        "meta" =>
          source_meta
          |> normalize_meta()
          |> Map.drop([
            :native_destination_pid,
            "native_destination_pid",
            "nativeDestinationPid",
            :nativeDestinationPid,
            :native_destination_generation,
            "native_destination_generation",
            :nativeDestinationGeneration,
            "nativeDestinationGeneration",
            :native_source_profile_id,
            "native_source_profile_id",
            :nativeSourceProfileId,
            "nativeSourceProfileId",
            :native_source_session_key,
            "native_source_session_key",
            :nativeSourceSessionKey,
            "nativeSourceSessionKey",
            :native_followup_submit,
            "native_followup_submit",
            :nativeFollowupSubmit,
            "nativeFollowupSubmit",
            :native_source_floor_fun,
            "native_source_floor_fun",
            :nativeSourceFloorFun,
            "nativeSourceFloorFun",
            :native_managed_context,
            "native_managed_context",
            :nativeManagedContext,
            "nativeManagedContext",
            :remote_cwd,
            "remote_cwd",
            :remote_cwd_explicit,
            "remote_cwd_explicit"
          ])
      }

      json_round_trip(payload, opts)
    end
  end

  def encode(_, _opts), do: {:error, :invalid_execution_request}

  defp validate_context_run_id(%ExecutionContext{run_id: run_id}, run_id), do: :ok

  defp validate_context_run_id(_context, _run_id),
    do: {:error, :execution_context_run_id_mismatch}

  defp normalize_source_meta(nil), do: {:ok, %{}}

  defp normalize_source_meta(meta) when is_map(meta) do
    with {:ok, meta} <- normalize_private_keys(meta, @private_meta_aliases),
         {:ok, meta} <- normalize_source_proof(meta) do
      {:ok, meta}
    end
  end

  defp normalize_source_meta(_),
    do: {:error, {:invalid_request_payload, :invalid_execution_meta}}

  defp normalize_source_proof(%{invocation_proof: proof} = meta)
       when is_map(proof) and not is_struct(proof) do
    with {:ok, proof} <- normalize_private_keys(proof, @proof_meta_aliases) do
      {:ok, Map.put(meta, :invocation_proof, proof)}
    end
  end

  defp normalize_source_proof(meta), do: {:ok, meta}

  defp normalize_private_keys(meta, fields) do
    Enum.reduce_while(fields, {:ok, meta}, fn {key, aliases}, {:ok, acc} ->
      case Map.fetch(acc, key) do
        {:ok, _trusted_value} ->
          # Presence, not truthiness: false/nil must defeat forged JSON aliases.
          {:cont, {:ok, Map.drop(acc, aliases)}}

        :error ->
          case alias_claim(acc, aliases) do
            :absent ->
              {:cont, {:ok, acc}}

            :untrusted ->
              # Reject rather than dropping scoped claims into legacy defaults.
              {:halt, {:error, {:invalid_request_payload, :untrusted_execution_context}}}

            negative ->
              # Preserve existing false/nil presence without minting proof.
              value = if negative == false, do: false, else: nil
              remaining = acc |> Map.drop(aliases) |> Map.put(Atom.to_string(key), value)
              {:cont, {:ok, remaining}}
          end
      end
    end)
  end

  defp alias_claim(meta, aliases) do
    Enum.reduce_while(aliases, :absent, fn alias_key, previous ->
      case Map.fetch(meta, alias_key) do
        :error -> {:cont, previous}
        {:ok, false} -> {:cont, false}
        {:ok, nil} -> {:cont, if(previous == false, do: false, else: nil)}
        {:ok, _meaningful_claim} -> {:halt, :untrusted}
      end
    end)
  end

  @spec decode_result(term()) :: {:ok, map()} | {:error, term()}
  def decode_result(result) when is_map(result) do
    completed = field(result, "completed") || result

    with true <- is_map(completed),
         ok when is_boolean(ok) <- field(completed, "ok") do
      {:ok,
       %{
         ok: ok,
         answer: normalize_answer(field(completed, "answer")),
         error: field(completed, "error"),
         usage: field(completed, "usage"),
         meta: field(completed, "meta"),
         resume: decode_resume(field(completed, "resume"))
       }}
    else
      _ -> {:error, :invalid_remote_result}
    end
  end

  def decode_result(_), do: {:error, :invalid_remote_result}

  defp remote_cwd(%ExecutionRequest{meta: meta, cwd: cwd}) when is_map(meta) do
    case field(meta, "remote_cwd_explicit") do
      true -> field(meta, "remote_cwd")
      false -> nil
      _ -> cwd
    end
  end

  defp remote_cwd(%ExecutionRequest{cwd: cwd}), do: cwd

  defp encode_resume(%ResumeToken{engine: engine, value: value}),
    do: %{"engine" => engine, "value" => value}

  defp encode_resume(%{engine: engine, value: value}) when is_binary(engine) and is_binary(value),
    do: %{"engine" => engine, "value" => value}

  defp encode_resume(_), do: nil

  defp decode_resume(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value),
       do: %ResumeToken{engine: engine, value: value}

  defp decode_resume(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value),
       do: %ResumeToken{engine: engine, value: value}

  defp decode_resume(_), do: nil

  defp encode_atom(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode_atom(value), do: value

  defp normalize_answer(value) when is_binary(value), do: value
  defp normalize_answer(nil), do: ""
  defp normalize_answer(value), do: inspect(value)

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> existing_atom_value(map, key)
    end
  end

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp json_round_trip(payload, opts) do
    case LemonCore.JSONPayload.round_trip(payload, LemonCore.ToolPolicy.execution_json_opts(opts)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_request_payload, reason}}
    end
  end
end
