defmodule LemonPlatformTest.EchoEngineComplianceTest do
  @moduledoc """
  The kit's `EngineCase` run against the platform's reference engine.

  Echo answers in-process without touching a model, so this is the one
  self-validation that can afford to run the full lifecycle (`:run_probe`)
  rather than the static contract alone.
  """

  use LemonPlatformTest.EngineCase,
    async: false,
    engine: LemonGateway.Engines.Echo,
    run_probe: {__MODULE__, :job}

  def job(_context) do
    %LemonGateway.Types.Job{
      run_id: "platform-test-#{System.unique_integer([:positive])}",
      session_key: "agent:platform_test:main",
      prompt: "ping",
      engine_id: "echo"
    }
  end
end
