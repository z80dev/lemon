defmodule CodingAgent.Executor.RemoteRequestCodec do
  @moduledoc """
  Builds the JSON boundary for a named-node coding-agent invocation.

  Only execution request data crosses the boundary. Runtime executor options,
  resolved provider credentials, callbacks, and source-node process state are
  intentionally excluded. For delegated agent requests, `remote_cwd_explicit`
  distinguishes an explicit destination path from the source router's default
  cwd; omitted remote cwd is encoded as `nil` for destination-local resolution.
  """

  alias LemonCore.ResumeToken
  alias LemonGateway.ExecutionRequest

  @version 1

  @execution_meta_keys ~w(model thinking_level system_prompt profile_id profile_instructions
                          mcp_servers agent_id async_followups resume_source acp_session_id
                          acp_mcp_session_id acp_client_terminal acp_client_elicitation_form
                          acp_client_fs_read_text_file acp_client_fs_write_text_file)a

  @doc false
  def normalize_meta(meta) when is_map(meta) do
    Enum.reduce(@execution_meta_keys, meta, fn key, acc ->
      case Map.fetch(acc, Atom.to_string(key)) do
        {:ok, value} -> acc |> Map.delete(Atom.to_string(key)) |> Map.put(key, value)
        :error -> acc
      end
    end)
  end

  def normalize_meta(_), do: %{}

  @spec encode(ExecutionRequest.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def encode(request, opts \\ [])

  def encode(%ExecutionRequest{} = request, opts) do
    native_images = if is_nil(request.images), do: [], else: request.images

    with {:ok, images} <- LemonAi.ImageInputs.encode(native_images) do
      payload = %{
        "version" => @version,
        "runId" => request.run_id,
        "sessionKey" => request.session_key,
        "prompt" => request.prompt,
        "images" => images,
        "cwd" => remote_cwd(request),
        "resume" => encode_resume(request.resume),
        "lane" => encode_atom(request.lane),
        "toolPolicy" => request.tool_policy,
        # Cwd routing hints are consumed above, not execution metadata. In particular
        # an unused controller path must not survive through a false explicit flag.
        "meta" =>
          Map.drop(request.meta || %{}, [
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
