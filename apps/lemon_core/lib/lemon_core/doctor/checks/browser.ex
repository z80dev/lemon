defmodule LemonCore.Doctor.Checks.Browser do
  @moduledoc "Checks browser preview proof readiness from redacted local smoke artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @required_tools [
    "browser_navigate",
    "browser_wait_for_selector",
    "browser_evaluate",
    "browser_hover",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_snapshot",
    "browser_type",
    "browser_click",
    "browser_screenshot",
    "browser_screenshot_include_image",
    "media_analyze_image_local_vision",
    "browser_analyze_local_vision",
    "browser_get_content",
    "browser_events",
    "browser_set_cookies",
    "browser_get_cookies",
    "browser_clear_state",
    "browser_cdp_attach_mode"
  ]

  @required_flags [
    :model_visible_image_included,
    :browser_to_media_vision_completed,
    :browser_wait_for_selector_completed,
    :browser_evaluate_completed,
    :browser_hover_completed,
    :browser_select_option_completed,
    :browser_upload_file_completed,
    :browser_download_completed,
    :browser_analyze_completed,
    :browser_analyze_model_visible_image_included,
    :browser_cdp_attach_completed,
    :browser_navigation_metadata_blocked,
    :browser_navigation_public_route_guarded
  ]

  @cleanup_flags [
    :contains_raw_sensitive_values,
    :includes_raw_urls,
    :includes_selectors,
    :includes_typed_text,
    :includes_cookie_values,
    :includes_page_text,
    :includes_artifact_paths,
    :includes_raw_paths,
    :includes_screenshot_bytes
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_browser_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "browser.preview",
          "Browser proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_browser_preview(proofs) do
    case latest_browser_proof(proofs) do
      nil ->
        Check.skip("browser.preview", "Browser preview proof has not been generated yet.")

      proof ->
        cond do
          proof_ready?(proof) ->
            Check.pass(
              "browser.preview",
              "Browser preview proof is completed for the supervised local driver, CDP attach mode, route guardrails, page interaction, upload/download, screenshots, cookies, progress redaction, and browser-to-media vision."
            )

          proof_failed?(proof) ->
            Check.warn(
              "browser.preview",
              "Browser preview proof is failed or incomplete.",
              remediation()
            )

          true ->
            Check.warn(
              "browser.preview",
              "Browser preview proof is incomplete.",
              remediation()
            )
        end
    end
  end

  defp latest_browser_proof(proofs) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.find(fn proof -> "browser_smoke" in Map.get(proof, :proof_scopes, []) end)
  end

  defp proof_ready?(proof) do
    browser = Map.get(proof, :browser_proof, %{})

    Map.get(proof, :status) == "completed" and
      Map.get(proof, :completed_count, 0) >= length(@required_tools) and
      Map.get(proof, :failed_count, 1) == 0 and
      Map.get(browser, :progress_update_count, 0) >= length(@required_tools) * 2 and
      Map.get(browser, :progress_browser_child_action_count, 0) >= length(@required_tools) and
      tools_present?(browser) and
      flags_true?(browser) and
      cleanup_clean?(browser)
  end

  defp proof_failed?(proof) do
    Map.get(proof, :status) == "failed" or Map.get(proof, :failed_count, 0) > 0
  end

  defp tools_present?(browser) do
    tools = MapSet.new(Map.get(browser, :exercised_tools, []))
    Enum.all?(@required_tools, &MapSet.member?(tools, &1))
  end

  defp flags_true?(browser) do
    Enum.all?(@required_flags, &(Map.get(browser, &1) == true))
  end

  defp cleanup_clean?(browser) do
    cleanup = Map.get(browser, :cleanup, %{})
    Enum.all?(@cleanup_flags, &(Map.get(cleanup, &1) == false))
  end

  defp remediation do
    "Run MIX_ENV=test mix run scripts/live_browser_smoke.exs and keep the redacted proof at .lemon/proofs/browser-smoke-latest.json."
  end
end
