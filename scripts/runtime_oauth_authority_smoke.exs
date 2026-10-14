# Run from the umbrella root against the existing compiled baseline:
# MIX_ENV=test mix run --no-compile --no-start scripts/runtime_oauth_authority_smoke.exs
# Offline, no ExUnit: public LemonAgent.agent_loop -> LemonAi -> real HTTP loopback.
Code.require_file("support/oauth_authority_probe.exs", __DIR__)

defmodule LemonScripts.RuntimeOAuthAuthoritySmoke do
  def main do
    root =
      Path.join(
        System.tmp_dir!(),
        "runtime_oauth_authority_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    System.put_env("HOME", root)
    System.put_env("LEMON_STORE_PATH", Path.join(root, "store"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, :paths, home_dir: root)

    try do
      {:ok, _} = Application.ensure_all_started(:lemon_agent)

      reports =
        for provider <- [:xai, :github_copilot, :kimi_coding, :anthropic],
            scenario <- [:missing, :env_only, :expired, :encoded, :success] do
          result = LemonScripts.OAuthAuthorityProbe.run(root, provider, scenario)

          expected =
            if scenario == :success,
              do: result.requests == 1 and result.selected_authority and result.answered,
              else: result.requests == 0 and result.refused

          Map.merge(result, %{
            provider: provider,
            scenario: scenario,
            passed: expected and not result.credential_leak and not result.wrong_principal
          })
        end

      Enum.each(reports, &IO.puts(Jason.encode!(&1)))

      unless Enum.all?(reports, & &1.passed),
        do: raise("selected OAuth authority violated; see redacted loopback counts above")
    after
      File.rm_rf!(root)
    end
  end
end

LemonScripts.RuntimeOAuthAuthoritySmoke.main()
