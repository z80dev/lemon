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

  @spec encode(ExecutionRequest.t()) :: {:ok, map()} | {:error, term()}
  def encode(%ExecutionRequest{} = request) do
    payload = %{
      "version" => @version,
      "runId" => request.run_id,
      "sessionKey" => request.session_key,
      "prompt" => request.prompt,
      "images" => request.images || [],
      "cwd" => remote_cwd(request),
      "resume" => encode_resume(request.resume),
      "lane" => encode_atom(request.lane),
      "toolPolicy" => request.tool_policy,
      "meta" => request.meta || %{}
    }

    json_round_trip(payload)
  end

  def encode(_), do: {:error, :invalid_execution_request}

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
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp json_round_trip(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, {:request_not_json_safe, reason}}
    end
  end
end
