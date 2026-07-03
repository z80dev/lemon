defmodule LemonControlPlane.Methods.LspServerInitialize do
  @moduledoc """
  Handler for `lsp.server.initialize`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.server.initialize"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_id} <- required(params, "sessionId"),
         {:ok, timeout_ms} <- timeout_ms(params),
         {:ok, response} <-
           LemonLsp.ServerManager.initialize_session(
             session_id,
             get_param(params, "params") || %{},
             timeout_ms: timeout_ms
           ) do
      {:ok, response |> Map.put(:summary, summary(response, timeout_ms)) |> stringify_keys()}
    else
      {:error, :missing_session_id} ->
        {:error, {:invalid_request, "sessionId is required"}}

      {:error, :unknown_lsp_session} ->
        {:error, {:not_found, "LSP session was not found"}}

      {:error, :invalid_params} ->
        {:error, {:invalid_request, "params must be an object, array, or null"}}

      {:error, :invalid_timeout} ->
        {:error, {:invalid_request, "timeoutMs must be between 50 and 60000"}}

      {:error, :request_timeout} ->
        {:error, {:timeout, "LSP initialize timed out"}}

      {:error, :session_stopped} ->
        {:error, {:unavailable, "LSP session stopped before initialize completed"}}

      {:error, :session_exited} ->
        {:error, {:unavailable, "LSP session exited before initialize completed"}}

      {:error, error} ->
        {:error, {:internal_error, "Failed to initialize LSP server", inspect(error)}}
    end
  end

  defp required(params, key) do
    value = get_param(params, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :missing_session_id}
    end
  end

  defp timeout_ms(params) do
    case get_param(params, "timeoutMs") do
      nil -> {:ok, 5_000}
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value

  defp summary(response, timeout_ms) do
    result_returned = has_key?(response, "result")
    error_returned = has_key?(response, "error")

    %{
      action: :initialize,
      method: "initialize",
      timeout_ms: timeout_ms,
      result_returned: result_returned,
      error_returned: error_returned,
      protocol_response_returned: true,
      raw_session_id_returned: false,
      cleanup: %{
        includes_raw_session_id: false,
        includes_request_params: false,
        includes_protocol_result: result_returned,
        includes_protocol_error: error_returned,
        includes_server_io: false,
        includes_credentials: false,
        includes_secret_values: false
      }
    }
  end

  defp has_key?(map, "result") when is_map(map),
    do: Map.has_key?(map, "result") or Map.has_key?(map, :result)

  defp has_key?(map, "error") when is_map(map),
    do: Map.has_key?(map, "error") or Map.has_key?(map, :error)

  defp has_key?(_map, _key), do: false
end
