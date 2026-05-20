defmodule LemonControlPlane.Methods.LspDiagnosticsStatus do
  @moduledoc """
  Handler for `lsp.diagnostics.status`.

  Returns redacted LSP diagnostics capability metadata and checker availability
  without file paths, workspace roots, diagnostic output, or file contents.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "lsp.diagnostics.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    project_dir = params["projectDir"] || params["project_dir"] || File.cwd!()

    payload =
      params
      |> opts()
      |> LemonCore.Doctor.LspDiagnostics.status()
      |> Map.put(:proofs, lsp_proof_status(project_dir))
      |> stringify_keys()

    {:ok, Map.put(payload, "summary", summary(payload))}
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build LSP diagnostics status",
         Exception.message(error)
       }}
  end

  defp summary(payload) do
    server_manager = Map.get(payload, "server_manager", %{})
    registry = Map.get(server_manager, "registry", %{})
    proofs = Map.get(payload, "proofs", %{})
    executable_summary = Map.get(payload, "executable_summary", %{})

    %{
      "action" => name(),
      "status" => Map.get(payload, "status"),
      "defaultTimeoutMs" => Map.get(payload, "default_timeout_ms"),
      "supportedLanguageCount" => Map.get(payload, "supported_language_count", 0),
      "availableExecutableCount" => Map.get(executable_summary, "available_count", 0),
      "serverManagerRunning" => Map.get(server_manager, "running") == true,
      "serverRegistryCount" => Map.get(registry, "count", 0),
      "proofCount" => Map.get(proofs, "proof_count", 0),
      "checkCount" => Map.get(proofs, "check_count", 0),
      "proofErrorReturned" => is_binary(Map.get(proofs, "error")),
      "cleanup" => Map.get(payload, "cleanup", %{}),
      "proofCleanup" => Map.get(proofs, "cleanup", %{})
    }
  end

  defp opts(params) do
    []
    |> maybe_put(:diagnostics_timeout_ms, get_param(params, "diagnosticsTimeoutMs"))
  end

  defp lsp_proof_status(project_dir) do
    status = LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    matching_proofs =
      status
      |> Map.get(:recent_proofs, [])
      |> Enum.filter(&lsp_proof?/1)

    matching_checks =
      status
      |> Map.get(:latest_checks, [])
      |> Enum.filter(&lsp_check?/1)

    %{
      recent_proofs: Enum.take(matching_proofs, 4),
      latest_checks: Enum.take(matching_checks, 8),
      proof_count: length(matching_proofs),
      check_count: length(matching_checks),
      cleanup: proof_cleanup(),
      error: nil
    }
  rescue
    error -> empty_lsp_proof_status(Exception.message(error))
  catch
    kind, reason -> empty_lsp_proof_status(inspect({kind, reason}))
  end

  defp empty_lsp_proof_status(error) do
    %{
      recent_proofs: [],
      latest_checks: [],
      proof_count: 0,
      check_count: 0,
      cleanup: proof_cleanup(),
      error: error
    }
  end

  defp lsp_proof?(proof) when is_map(proof) do
    proof
    |> Map.take([:proof_object, :reason_kind, :proof_scopes])
    |> Map.values()
    |> safe_text_join()
    |> String.downcase()
    |> String.contains?("lsp")
  end

  defp lsp_proof?(_proof), do: false

  defp lsp_check?(check) when is_map(check) do
    check_text =
      check
      |> Map.take([:name, :proof_object, :reason_kind])
      |> Map.values()
      |> safe_text_join()
      |> String.downcase()

    String.contains?(check_text, "lsp") or
      String.contains?(check_text, "pyright") or
      String.contains?(check_text, "gopls") or
      String.contains?(check_text, "clangd") or
      String.contains?(check_text, "rust_analyzer") or
      String.contains?(check_text, "typescript_language_server") or
      String.contains?(check_text, "elixir_ls")
  end

  defp lsp_check?(_check), do: false

  defp proof_cleanup do
    %{
      includes_raw_paths: false,
      includes_raw_filenames: false,
      includes_raw_proof_details: false,
      includes_raw_prompts: false,
      includes_raw_provider_responses: false,
      embeds_proof_file_contents: false
    }
  end

  defp safe_text_join(values) when is_list(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end

  defp safe_text_join(nil), do: ""
  defp safe_text_join(value), do: to_string(value)

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
end
