defmodule LemonControlPlane.Methods.LspServerStop do
  @moduledoc """
  Handler for `lsp.server.stop`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.server.stop"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_id} <- required(params, "sessionId"),
         {:ok, session} <- LemonCore.LspServerManager.stop_session(session_id) do
      {:ok, session |> Map.put(:summary, summary(session)) |> stringify_keys()}
    else
      {:error, :missing_session_id} ->
        {:error, {:invalid_request, "sessionId is required"}}

      {:error, :unknown_lsp_session} ->
        {:error, {:not_found, "LSP session was not found"}}

      {:error, error} ->
        {:error, {:internal_error, "Failed to stop LSP server", inspect(error)}}
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

  defp summary(session) do
    %{
      action: :stop,
      server_id: Map.get(session, :server_id),
      status: Map.get(session, :status),
      diagnostic_count: Map.get(session, :diagnostic_count, 0),
      pending_request_count: Map.get(session, :pending_request_count, 0),
      session_id_returned: Map.has_key?(session, :session_id),
      session_hash_returned: Map.has_key?(session, :session_hash),
      cleanup: %{
        includes_raw_session_id: Map.has_key?(session, :session_id),
        includes_raw_cwd: false,
        includes_executable_path: false,
        includes_server_io: false,
        includes_diagnostic_text: false,
        includes_credentials: false,
        includes_secret_values: false
      }
    }
  end
end
