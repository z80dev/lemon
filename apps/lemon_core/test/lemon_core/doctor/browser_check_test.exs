defmodule LemonCore.Doctor.BrowserCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.BrowserProvider
  alias LemonCore.Doctor.Checks.Browser

  test "auto reports the chosen provider and resolver reason without starting a runtime" do
    opts = [
      config: %{provider: "auto"},
      lcu_probe: fn -> {:error, "missing"} end,
      probe: fn
        "relay" -> {:error, "missing"}
        "local" -> {:ok, "ready"}
      end
    ]

    result = BrowserProvider.resolve(opts)
    assert [%{name: "browser.provider", status: :pass, message: message}] = Browser.run(opts)
    assert message == "auto -> local: #{result.reason}"
  end

  test "explicit unavailable provider fails closed and reports the core reason" do
    opts = [config: %{provider: "lcu"}, lcu_probe: fn -> {:error, "secret=/private/token"} end]
    result = BrowserProvider.resolve(opts)
    assert [%{status: :fail, message: message}] = Browser.run(opts)
    assert message == "lcu -> unavailable: #{result.reason}"
    refute message =~ "secret"
    refute message =~ "/private"
  end

  test "auto with no available provider warns rather than claiming LCU is selected" do
    opts = [
      config: %{provider: "auto"},
      lcu_probe: fn -> {:error, "missing"} end,
      probe: fn _ -> {:error, "missing"} end
    ]

    assert [%{status: :warn, message: message}] = Browser.run(opts)
    assert message =~ "auto -> unavailable:"
  end
end
