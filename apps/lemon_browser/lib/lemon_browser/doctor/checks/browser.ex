defmodule LemonBrowser.Doctor.Checks.Browser do
  @moduledoc "Read-only browser provider selection diagnostics."

  alias LemonBrowser.Provider
  alias LemonCore.Doctor.Check

  def run(opts) do
    result = Provider.resolve(opts)
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
