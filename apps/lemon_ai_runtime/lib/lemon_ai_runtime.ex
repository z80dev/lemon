defmodule LemonAiRuntime do
  @moduledoc """
  Lemon-owned AI runtime boundary.

  In the first extraction slice this app is intentionally façade-only:
  `LemonAiRuntime.Auth.*` delegates to the current `Ai.Auth.*` implementation
  so Lemon apps can stop depending on `Ai.Auth.*` directly before the real
  implementation moves out of `apps/ai`.
  """
end

