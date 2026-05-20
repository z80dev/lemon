defmodule LemonControlPlane.ACP.NDJSON do
  @moduledoc """
  Newline-delimited JSON transport for ACP stdio clients.
  """

  def run(input \\ IO.stream(:stdio, :line), output \\ :stdio) do
    pending = :ets.new(:lemon_acp_ndjson_pending, [:set, :public])
    state = :ets.new(:lemon_acp_ndjson_state, [:set, :public])

    Enum.each(input, fn line ->
      handle_line(line, output, pending, state)
    end)
  end

  def responses_for_line(line, opts \\ []) when is_binary(line) do
    case String.trim(line) do
      "" ->
        []

      trimmed ->
        trimmed
        |> Jason.decode()
        |> case do
          {:ok, request} -> encode_result(LemonControlPlane.ACP.handle_jsonrpc(request, opts))
          {:error, _reason} -> [Jason.encode!(parse_error())]
        end
    end
  end

  defp handle_line(line, output, pending, state) do
    case String.trim(line) do
      "" ->
        :ok

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"id" => id} = response}
          when not is_map_key(response, "method") and
                 (is_map_key(response, "result") or is_map_key(response, "error")) ->
            deliver_client_response(pending, id, response)

          {:ok, request} ->
            maybe_store_client_capabilities(state, request)

            Task.start(fn ->
              opts = [
                session_update_callback: fn message -> write_json(output, message) end,
                client_request_callback: fn request ->
                  request_client_response(output, pending, request)
                end,
                client_capabilities: client_capabilities(state)
              ]

              request
              |> LemonControlPlane.ACP.handle_jsonrpc(opts)
              |> encode_result()
              |> Enum.each(&IO.write(output, &1 <> "\n"))
            end)

          {:error, _reason} ->
            write_json(output, parse_error())
        end
    end
  end

  defp maybe_store_client_capabilities(state, %{
         "method" => "initialize",
         "params" => %{"clientCapabilities" => capabilities}
       }) do
    :ets.insert(
      state,
      {:client_capabilities, LemonControlPlane.ACP.normalize_client_capabilities(capabilities)}
    )
  end

  defp maybe_store_client_capabilities(_state, _request), do: :ok

  defp client_capabilities(state) do
    case :ets.lookup(state, :client_capabilities) do
      [{:client_capabilities, capabilities}] -> capabilities
      [] -> nil
    end
  end

  defp request_client_response(output, pending, request) do
    id = "lemon_req_#{System.unique_integer([:positive])}"

    try do
      request = Map.put(request, "id", id)
      :ets.insert(pending, {id, self()})
      write_json(output, request)

      receive do
        {:acp_client_response, ^id, response} -> {:ok, response}
      after
        60_000 -> {:error, :timeout}
      end
    after
      :ets.delete(pending, id)
    end
  end

  defp deliver_client_response(pending, id, response) do
    case :ets.lookup(pending, id) do
      [{^id, pid}] -> send(pid, {:acp_client_response, id, response})
      [] -> :ok
    end
  end

  defp write_json(output, message), do: IO.write(output, Jason.encode!(message) <> "\n")

  defp encode_result(:noreply), do: []
  defp encode_result({:ok, response}) when response == :noreply, do: []
  defp encode_result({:ok, responses}) when is_list(responses), do: [Jason.encode!(responses)]
  defp encode_result({:ok, response}), do: [Jason.encode!(response)]

  defp parse_error do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32700,
        "message" => "parse error"
      }
    }
  end
end
