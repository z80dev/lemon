Code.require_file("support/setup_verification_probe.exs", __DIR__)
Code.require_file("support/setup_onboarding_probe.exs", __DIR__)

root = Path.join(System.tmp_dir!(), "setup_verification_#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
System.put_env("HOME", root)
System.put_env("LEMON_STORE_PATH", Path.join(root, "store"))
System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
Application.put_env(:lemon_core, :paths, home_dir: root)
Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env])
LemonCli.Onboarding.Runner.ensure_required_apps!()
# Capture diagnostics in the probe but never print raw handler output.
:logger.remove_handler(:default)

try do
  rows =
    for scenario <- [:success, :raw_success, :expired, :unavailable, :encoded, :keyless, :skip] do
      result = LemonScripts.SetupVerificationProbe.run(root, scenario)
      IO.puts(Jason.encode!(Map.put(result, :scenario, scenario)))
      {scenario, result}
    end

  if System.get_env("SETUP_VERIFICATION_EXPECT_FIXED") == "1" do
    xai_rows =
      for scenario <- [:success, :raw_success, :expired, :unavailable, :encoded] do
        result = LemonScripts.SetupVerificationProbe.run(root, scenario, :xai)
        IO.puts(Jason.encode!(Map.merge(result, %{provider: :xai, scenario: scenario})))
        {scenario, result}
      end

    file_result = LemonScripts.SetupVerificationProbe.run(root, :success, :xai, :file)

    IO.puts(
      Jason.encode!(
        Map.merge(file_result, %{provider: :xai, scenario: :success, config_source: :file})
      )
    )

    rows = rows ++ xai_rows ++ [{:success, file_result}]

    valid? =
      Enum.all?(rows, fn {scenario, r} ->
        clean =
          not r.wire_credential_leak and not r.log_credential_leak and not r.event_credential_leak and
            not r.wrong_principal

        clean and
          case scenario do
            s when s in [:success, :raw_success] ->
              r.live_ok and r.requests == 1 and r.configured_requests == 1 and r.correct_access and
                r.correct_scope_header and r.models_get

            :keyless ->
              r.live_ok and r.configured_requests == 1 and r.keyless_wire

            :skip ->
              r.disabled and r.requests == 0

            _ ->
              r.refused and not r.success and r.requests == 0
          end
      end)

    unless valid?,
      do:
        raise("Public setup verification authority assertions failed; see bounded results above")

    for entry <- [:provider, :wizard] do
      r = LemonScripts.SetupOnboardingProbe.run(root, entry)
      IO.puts(Jason.encode!(Map.put(r, :entry, entry)))

      unless r.success and r.requests == 1 and r.correct_access and r.correct_scope_header and
               r.models_get and not r.event_credential_leak,
             do:
               raise("Public setup onboarding wire assertions failed; see bounded results above")
    end

    r = LemonScripts.SetupOnboardingProbe.run(root, :provider, false)
    IO.puts(Jason.encode!(Map.put(r, :entry, :offline_model)))

    unless r.success and r.requests == 0 and not r.event_credential_leak,
      do: raise("Offline model onboarding assertions failed; see bounded results above")
  end
after
  LemonCore.Secrets.table()
  |> LemonCore.Store.list()
  |> Enum.each(fn {key, _} -> LemonCore.Store.delete(LemonCore.Secrets.table(), key) end)

  File.rm_rf!(root)
end
