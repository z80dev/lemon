defmodule LemonControlPlane.Methods.LspServerStart do
  @moduledoc """
  Handler for `lsp.server.start`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.server.start"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, server_id} <- required(params, "serverId"),
         opts <- opts(params),
         {:ok, session} <- LemonCore.LspServerManager.start_session(server_id, opts) do
      {:ok, session |> Map.put(:summary, summary(session)) |> stringify_keys()}
    else
      {:error, :missing_server_id} ->
        {:error, {:invalid_request, "serverId is required"}}

      {:error, :unknown_lsp_server} ->
        {:error, {:invalid_request, "unknown LSP server"}}

      {:error, :command_unavailable} ->
        {:error, {:unavailable, "LSP server command is not available"}}

      {:error, :invalid_cwd} ->
        {:error, {:invalid_request, "cwd must be an existing directory"}}

      {:error, :duplicate_lsp_session} ->
        {:error, {:invalid_request, "LSP session id already exists"}}

      {:error, error} ->
        {:error, {:internal_error, "Failed to start LSP server", inspect(error)}}
    end
  end

  defp required(params, key) do
    value = get_param(params, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :missing_server_id}
    end
  end

  defp opts(params) do
    []
    |> maybe_put(:cwd, get_param(params, "cwd"))
    |> maybe_put(:session_id, get_param(params, "sessionId"))
  end

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value

  defp summary(session) do
    %{
      action: :start,
      server_id: Map.get(session, :server_id),
      status: Map.get(session, :status),
      session_id_returned: Map.has_key?(session, :session_id),
      session_hash_returned: Map.has_key?(session, :session_hash),
      command_name_returned: not is_nil(Map.get(session, :command)),
      cwd_hash_returned: not is_nil(Map.get(session, :cwd_hash)),
      cleanup: %{
        includes_raw_session_id: Map.has_key?(session, :session_id),
        includes_raw_cwd: false,
        includes_executable_path: false,
        includes_server_io: false,
        includes_credentials: false,
        includes_secret_values: false
      }
    }
  end
end
