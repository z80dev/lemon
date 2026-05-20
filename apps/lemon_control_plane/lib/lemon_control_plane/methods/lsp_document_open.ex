defmodule LemonControlPlane.Methods.LspDocumentOpen do
  @moduledoc """
  Handler for `lsp.document.open`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.document.open"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_id} <- required(params, "sessionId", :missing_session_id),
         {:ok, uri} <- required(params, "uri", :missing_uri),
         {:ok, language_id} <- required(params, "languageId", :missing_language_id),
         {:ok, text} <- text(params),
         {:ok, version} <- version(params),
         {:ok, document} <-
           LemonCore.LspServerManager.open_document(session_id, uri, language_id, text,
             version: version
           ) do
      {:ok, document |> Map.put(:summary, summary(document)) |> stringify_keys()}
    else
      {:error, :missing_session_id} ->
        {:error, {:invalid_request, "sessionId is required"}}

      {:error, :missing_uri} ->
        {:error, {:invalid_request, "uri is required"}}

      {:error, :missing_language_id} ->
        {:error, {:invalid_request, "languageId is required"}}

      {:error, :missing_text} ->
        {:error, {:invalid_request, "text is required"}}

      {:error, :unknown_lsp_session} ->
        {:error, {:not_found, "LSP session was not found"}}

      {:error, :invalid_document_uri} ->
        {:error, {:invalid_request, "uri is invalid"}}

      {:error, :invalid_language_id} ->
        {:error, {:invalid_request, "languageId is invalid"}}

      {:error, :invalid_document_text} ->
        {:error, {:invalid_request, "text must be a string"}}

      {:error, :invalid_document_version} ->
        {:error, {:invalid_request, "version is invalid"}}

      {:error, error} ->
        {:error, {:internal_error, "Failed to open LSP document", inspect(error)}}
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

  defp text(params) do
    case get_param(params, "text") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_text}
      _value -> {:error, :invalid_document_text}
    end
  end

  defp version(params) do
    case get_param(params, "version") do
      nil -> {:ok, 1}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, :invalid_document_version}
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
      action: :open,
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
