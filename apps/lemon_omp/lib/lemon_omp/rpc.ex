defmodule LemonOmp.Rpc do
  @moduledoc """
  Pure codec for omp's RPC mode (`omp --mode rpc`), protocol v1.

  The wire is newline-delimited JSON over stdio: commands on stdin, and on
  stdout a `ready` frame, command responses, session events and side-channel
  requests. Lemon stays on protocol v1, whose physical frames are capped at
  1 MiB by the server; it never negotiates the chunked v2 transport, so every
  stdout line is one complete JSON object. The canonical contract is omp's
  `docs/rpc.md` and `packages/coding-agent/src/modes/rpc/rpc-types.ts`.

  Everything decoded here is untrusted data from another program. Decoding never
  raises: malformed lines classify as `{:malformed, reason}` and the session
  counts and skips them.
  """

  @blocking_ui_methods ~w(select confirm input editor)

  @type frame ::
          {:ready, map()}
          | {:response, String.t() | nil, String.t(),
             {:ok, term()} | {:error, String.t(), term()}}
          | {:ui_request, String.t(), String.t(), map()}
          | {:host_request, String.t(), map()}
          | {:event, String.t(), map()}
          | {:malformed, atom()}

  @doc "Encode a command (map with string keys) as one JSONL line."
  @spec encode(map()) :: iodata()
  def encode(command) when is_map(command), do: [Jason.encode_to_iodata!(command), ?\n]

  @doc "Build a command map; `id` correlates the response."
  @spec command(String.t(), String.t(), map()) :: map()
  def command(type, id, fields \\ %{}) when is_binary(type) and is_binary(id) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{"type" => type, "id" => id})
  end

  @doc """
  Classify one stdout line.
  """
  @spec decode(binary()) :: frame()
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = frame} when is_binary(type) -> classify(type, frame)
      {:ok, _other} -> {:malformed, :not_a_frame}
      {:error, _} -> {:malformed, :invalid_json}
    end
  end

  defp classify("ready", frame), do: {:ready, frame}

  defp classify("response", frame) do
    id = string_or_nil(frame["id"])
    command = string_or_nil(frame["command"]) || "unknown"

    result =
      if frame["success"] == true do
        {:ok, frame["data"]}
      else
        {:error, string_or_nil(frame["error"]) || "omp rejected the command",
         string_or_nil(frame["code"])}
      end

    {:response, id, command, result}
  end

  defp classify("extension_ui_request", frame) do
    case {string_or_nil(frame["id"]), string_or_nil(frame["method"])} do
      {id, method} when is_binary(id) and is_binary(method) -> {:ui_request, id, method, frame}
      _ -> {:malformed, :invalid_ui_request}
    end
  end

  defp classify(type, frame) when type in ["host_tool_call", "host_uri_request"] do
    case string_or_nil(frame["id"]) do
      id when is_binary(id) -> {:host_request, id, frame}
      _ -> {:malformed, :invalid_host_request}
    end
  end

  defp classify(type, frame), do: {:event, type, frame}

  @doc """
  The reply a headless host owes a blocking extension UI request, or `nil`
  for fire-and-forget methods (`notify`, `setStatus`, `setWidget`, ...).

  Non-approval dialogs have no answer surface: confirms answer `false` and
  every other blocking method is cancelled. `LemonOmp.Session` bridges tool
  approval selects separately before falling back to this fail-closed reply.
  """
  @spec decline_ui_request(String.t(), String.t()) :: map() | nil
  def decline_ui_request(id, "confirm"),
    do: %{"type" => "extension_ui_response", "id" => id, "confirmed" => false}

  def decline_ui_request(id, method) when method in @blocking_ui_methods,
    do: %{"type" => "extension_ui_response", "id" => id, "cancelled" => true}

  def decline_ui_request(_id, _method), do: nil

  @doc """
  The reply for a host-tool or host-URI request. Lemon registers neither, so a
  request can only come from a confused or hostile peer; reject it.
  """
  @spec reject_host_request(String.t(), map()) :: map()
  def reject_host_request(id, %{"type" => "host_uri_request"}),
    do: %{
      "type" => "host_uri_result",
      "id" => id,
      "isError" => true,
      "error" => "not supported by host"
    }

  def reject_host_request(id, _frame),
    do: %{
      "type" => "host_tool_result",
      "id" => id,
      "isError" => true,
      "result" => %{"content" => [%{"type" => "text", "text" => "not supported by host"}]}
    }

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
