defmodule LemonCore.Doctor.Checks.Browser do
  @moduledoc "Read-only browser provider selection diagnostics."

  alias LemonCore.BrowserProvider
  alias LemonCore.Doctor.Check

  def run(opts) do
    result = BrowserProvider.resolve(opts)
    message = "#{result.requested} -> #{result.provider || "unavailable"}: #{result.reason}"

    check =
      cond do
        result.provider != nil -> Check.pass("browser.provider", message)
        result.requested == "auto" -> Check.warn("browser.provider", message)
        true -> Check.fail("browser.provider", message)
      end

    [check]
  end
end
