defmodule LemonComputerUse do
  @moduledoc """
  Native app control for Lemon agents through LCU.

  [LCU](https://github.com/amontlabs/lcu) runs the computer-use runtime that
  ships inside the official ChatGPT desktop app as a stdio MCP server
  (`<lcu-root>/bin/lcu`). This app talks to it through LCU's own shared harness
  client, from a small Node bridge it supervises, and contributes two agent
  tools — `cua_js` and `cua_js_reset` — plus the runtime's instructions as a
  system-prompt section. Native-app approval requests from the runtime become
  Lemon approvals (`LemonComputerUse.Approval`).

  It is opt-in: see `LemonComputerUse.Config`.
  """

  alias LemonComputerUse.Server

  @doc """
  Whether computer use is enabled for this runtime: the decision
  `LemonComputerUse.Application` resolved once at boot from the explicit
  switch (shared with the browser provider through
  `LemonCore.BrowserProvider.computer_use_enabled?/0`). `false` before boot.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: LemonCore.BrowserProvider, as: :computer_use_enabled?

  @doc "Bounded, redaction-safe status."
  @spec status() :: map()
  def status do
    if enabled?(),
      do: Map.put(Server.status(), :enabled, true),
      else: %{enabled: false, running: false}
  end
end
