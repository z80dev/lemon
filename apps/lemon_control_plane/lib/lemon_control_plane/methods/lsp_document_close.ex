defmodule LemonControlPlane.Methods.LspDocumentClose do
  @moduledoc """
  Handler for `lsp.document.close`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.document.close"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_id} <- required(params, "sessionId", :missing_session_id),
         {:ok, uri} <- required(params, "uri", :missing_uri),
         {:ok, document} <- LemonLsp.ServerManager.close_document(session_id, uri) do
      {:ok, document |> Map.put(:summary, summary(document)) |> stringify_keys()}
    else
      {:error, :missing_session_id} ->
        {:error, {:invalid_request, "sessionId is required"}}

      {:error, :missing_uri} ->
        {:error, {:invalid_request, "uri is required"}}

      {:error, :unknown_lsp_session} ->
        {:error, {:not_found, "LSP session was not found"}}

      {:error, :invalid_document_uri} ->
        {:error, {:invalid_request, "uri is invalid"}}

      {:error, error} ->
        {:error, {:internal_error, "Failed to close LSP document", inspect(error)}}
    end
  end

  defp required(params, key, reason) do
    value = get_param(params, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, reason}
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

  defp summary(document) do
    %{
      action: :close,
      status: Map.get(document, :status),
      version: Map.get(document, :version),
      text_bytes: Map.get(document, :text_bytes, 0),
      change_count: Map.get(document, :change_count, 0),
      raw_uri_returned: false,
      document_text_returned: false,
      cleanup: cleanup_summary()
    }
  end

  defp cleanup_summary do
    %{
      includes_raw_uri: false,
      includes_document_text: false,
      includes_credentials: false,
      includes_secret_values: false
    }
  end
end
