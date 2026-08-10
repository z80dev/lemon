defmodule CodingAgent.GatewayEngineContractTest do
  @moduledoc """
  The `"lemon"` engine, held to the published `LemonGateway.Engine` contract.

  `CodingAgent.GatewayEngine` lives outside `lemon_gateway` and registers itself
  at boot, so it is exactly the case third-party engines are in — which is why
  it is worth running the kit against it rather than against a stub.

  Two suite options are off:

    * `registry: false` — the registration round-trip would start `:lemon_gateway`
      inside this app's test run (binding its health port and starting its
      pollers). `LemonGateway.EngineRegistryTest` already covers runtime
      registration of an out-of-app engine, including surviving a restart.
    * no `:run_probe` — starting a real run means starting a real agent session
      against a real model.

  `cancel_tolerates_unknown_ctx: true` is on: this engine has the catch-all
  `cancel/1` clause that the CLI-backed engines lack.
  """

  use LemonPlatformTest.EngineCase,
    async: true,
    engine: CodingAgent.GatewayEngine,
    registry: false,
    cancel_tolerates_unknown_ctx: true
end
