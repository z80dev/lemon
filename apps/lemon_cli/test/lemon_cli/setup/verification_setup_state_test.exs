defmodule LemonCli.Setup.VerificationSetupStateTest do
  use ExUnit.Case, async: false

  alias LemonCli.Setup.Verification

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "verification_setup_state_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "config.toml")

    File.write!(path, """
    [defaults]
    provider = "openai-codex"
    model = "openai-codex:gpt-6.1-sol"

    [providers.openai-codex]
    auth_source = "api_key"
    api_key = "synthetic-codex-key"

    [providers.openai]
    api_key = "synthetic-openai-key"
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, path: path, cwd: root}
  end

  test "a caller-supplied setup state is used instead of deriving it again", %{
    path: path,
    cwd: cwd
  } do
    # A state that disagrees with the file proves the supplied one is used.
    supplied = %{
      config: %{complete: true, path: path},
      secrets: %{complete: true, source: :env},
      provider: %{
        complete: false,
        provider: nil,
        model: nil,
        credential_ready: false,
        reason: :missing_default_provider
      }
    }

    opts = [config_path: path, cwd: cwd, setup_state: supplied]

    assert {:error, %{step: :provider, reason: :missing_default_provider}} =
             Verification.verify_provider(
               opts ++ [verifier: fn _ -> flunk("no live check for an incomplete provider") end]
             )

    bound = Verification.verification_options(opts)
    assert Keyword.fetch!(bound, :setup_state) == supplied
    assert Keyword.fetch!(bound, :verification_model) == nil
  end

  test "live_input/1 carries the resolved model id and probe flag", %{path: path, cwd: cwd} do
    assert {:ok, input} = Verification.live_input(config_path: path, cwd: cwd)
    assert input.model_id == "gpt-6.1-sol"
    assert input.probe? == false
    assert input.api == :openai_codex_responses

    # Probing another provider uses that provider's probe model.
    assert {:ok, probe} =
             Verification.live_input(config_path: path, cwd: cwd, provider: "openai")

    assert probe.probe? == true
    assert is_binary(probe.model_id)
  end
end
