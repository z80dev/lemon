defmodule LemonCore.Setup.ReadinessTest do
  use ExUnit.Case, async: true

  alias LemonCore.Setup.Readiness

  test "pending steps remain ordered and ready?/1 agrees with them" do
    pending = %{
      config: %{complete: false, path: "/tmp/config.toml"},
      secrets: %{complete: true, source: :env},
      provider: %{
        complete: false,
        provider: "openai",
        model: nil,
        credential_ready: true,
        reason: :missing_default_model
      }
    }

    assert Readiness.pending_steps(pending) == [:config, :provider]
    refute Readiness.ready?(pending)

    ready =
      pending
      |> put_in([:config, :complete], true)
      |> put_in([:provider, :complete], true)
      |> put_in([:provider, :reason], nil)

    assert Readiness.pending_steps(ready) == []
    assert Readiness.ready?(ready)
  end
end
