defmodule LemonCli.Doctor.Providers do
  @moduledoc "Default-provider live diagnostics using setup's credential resolution."

  alias LemonCli.ProviderLiveCheck
  alias LemonCli.Setup.Verification
  alias LemonCore.Config
  alias LemonCore.Doctor.Check

  @spec run(keyword()) :: [Check.t()]
  def run(_opts), do: []

  @spec live_checks(keyword()) :: [LemonCore.Doctor.LiveChecks.job()]
  def live_checks(opts) do
    [{"providers.live", fn -> check(opts) end}]
  end

  defp check(opts) do
    config =
      Keyword.get(opts, :config) ||
        Config.load(Keyword.get(opts, :project_dir, File.cwd!()), cache: false)

    input_fn = Keyword.get(opts, :provider_live_input, &Verification.live_input/1)

    verifier =
      Keyword.get(
        opts,
        :provider_live_check,
        &ProviderLiveCheck.check(&1, Keyword.put(opts, :extended, true))
      )

    with {:ok, input} <- input_fn.(config: config, non_generating: true),
         {:ok, _} <- verifier.(input) do
      Check.pass("providers.live", "Default provider accepted a non-generating models request.")
    else
      {:skip, {:unsupported_api, _}} ->
        Check.skip("providers.live", "Skipped (no non-generating endpoint).")

      {:skip, _} ->
        Check.skip(
          "providers.live",
          "Skipped (default provider or model is not configured/resolvable)."
        )

      {:error, :credential_not_usable} ->
        Check.skip("providers.live", "Skipped (no usable provider credential).")

      {:error, reason} ->
        Check.fail("providers.live", ProviderLiveCheck.doctor_failure_message(reason))
    end
  rescue
    _ -> Check.fail("providers.live", "Provider live check could not complete.")
  end
end
