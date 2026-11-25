defmodule LemonCli.Doctor.Toolchain do
  @moduledoc """
  Reports the Elixir toolchain floor of the Lemon application as
  `runtime.elixir`.

  The floor belongs to the application, not to the published packages: a
  lemon_core consumer may run any Elixir its mix.exs admits. Registered via
  `config :lemon_core, :doctor_checks`.
  """

  alias LemonCore.Doctor.Check

  @minimum "1.20.5"

  @doc "The minimum Elixir version the Lemon application supports."
  @spec minimum() :: String.t()
  def minimum, do: @minimum

  @doc """
  Returns the `runtime.elixir` check. `:elixir_version` overrides
  `System.version/0` (tests).
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    [check(Keyword.get(opts, :elixir_version, System.version()))]
  end

  defp check(version) do
    supported? =
      case Version.parse(version) do
        {:ok, parsed} -> Version.compare(parsed, @minimum) != :lt
        :error -> false
      end

    if supported? do
      Check.pass("runtime.elixir", "Elixir #{version} meets the minimum version #{@minimum}.")
    else
      Check.fail(
        "runtime.elixir",
        "Elixir #{version} is unsupported; Lemon requires Elixir #{@minimum} or newer.",
        "Upgrade Elixir to #{@minimum}+ (with OTP 29.1.2+), then rerun `lemon doctor`."
      )
    end
  end
end
