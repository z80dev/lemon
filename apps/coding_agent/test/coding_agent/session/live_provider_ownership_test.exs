Code.require_file(
  Path.expand("../../../../../scripts/support/live_provider_ownership_probe.exs", __DIR__)
)

defmodule CodingAgent.Session.LiveProviderOwnershipTest do
  use ExUnit.Case, async: false
  alias LemonScripts.LiveProviderOwnershipProbe

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lpo-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    File.mkdir!(root)
    owner = self()
    LemonAgent.ModelRuntime.CredentialHealth.reset()
    LemonAgent.ModelRuntime.SessionPins.reset()

    on_exit(fn ->
      case :logger.get_handler_config(:live_provider_ownership_probe) do
        {:ok, %{module: LiveProviderOwnershipProbe, config: %{owner: ^owner}}} ->
          :logger.remove_handler(:live_provider_ownership_probe)

        _ ->
          :ok
      end

      File.rm_rf!(root)
      LemonAgent.ModelRuntime.CredentialHealth.reset()
      LemonAgent.ModelRuntime.SessionPins.reset()
    end)

    File.chmod!(root, 0o700)
    %{root: root}
  end

  test "idle native switch refuses missing selected OAuth instead of using ambient credentials",
       %{root: root} do
    report = run(root, :idle_missing)
    assert report.a_requests == 1
    assert report.selected_requests == 0
    assert report.refused
    refute report.answered
    assert report.journal_matches_selection
    refute report.private_values_in_logs_or_events
    assert report.passed
  end

  test "idle native plan-role selection retains selected OAuth refusal and model journal", %{
    root: root
  } do
    report = run(root, :plan_missing)
    assert report.a_requests == 1
    assert report.selected_requests == 0
    assert report.refused
    assert report.journal_matches_selection
    assert report.passed
  end

  test "idle native selected OAuth to keyless switch completes without Authorization", %{
    root: root
  } do
    report = run(root, :idle_keyless)
    assert report.selected_requests == 1
    assert report.keyless_requests == 1
    assert report.answered
    refute report.refused
    assert report.keyless_without_authorization
    assert report.journal_matches_selection
    refute report.private_values_in_logs_or_events
    assert report.passed
  end

  for scenario <- [:agent_missing, :agent_keyless] do
    test "public Agent idle #{scenario} binds destination options before real HTTP", %{
      root: root
    } do
      report = run(root, unquote(scenario))
      assert report.passed
      refute report.private_values_in_logs_or_events
    end
  end

  test "native live switch then fallback to startup provider strips foreign headers and selects pool key",
       %{root: root} do
    report = run(root, :live_fallback)
    assert report.a_requests == 2
    assert report.b_requests == 1
    assert report.answered
    refute report.foreign_header_on_a
    assert report.a_pool_selected
    assert report.b_explicit_header_preserved
    assert report.journal_matches_selection
    refute report.private_values_in_logs_or_events
    assert report.passed
  end

  test "same-provider idle rebinding and fallback wrapping preserve explicit caller headers", %{
    root: root
  } do
    report = run(root, :same_provider_headers)
    assert report.answered
    assert report.same_provider_header_preserved
    assert report.derived_headers_rebound_correctly
    assert report.passed
  end

  defp run(root, scenario) do
    LiveProviderOwnershipProbe.sandbox(root, fn ->
      LiveProviderOwnershipProbe.run(root, scenario)
    end)
  end
end
