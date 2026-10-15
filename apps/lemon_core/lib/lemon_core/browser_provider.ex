defmodule LemonCore.BrowserProvider do
  @moduledoc """
  The single passive browser-provider selection boundary.

  `resolve/1` never starts a runtime, browser, native host, or paid session. Auto
  tries connected LCU, configured/connected relay, then a usable local driver.
  Explicit selection fails closed and never falls back to another identity.

  Configuration is `runtime.tools.browser.provider` (default `auto`), overridden
  by `LEMON_BROWSER_PROVIDER`. Existing explicit `LEMON_BROWSER_BACKEND` and
  non-default browser application backend settings remain supported by Tools.

  Options may pin `:provider`, inject `:config` (a Config/Modular/Tools value or
  browser map), and supply `:probe` (arity-one function or module implementing
  `available?(provider_string)`) and `:lcu_probe` (arity-zero function). Runtime
  defaults are configured under `:lemon_core, :browser_provider_probe` and
  `:browser_provider_lcu_probe`; the optional browser module is referenced only
  at runtime. `:timeout_ms` bounds each probe (default 5 seconds). Probe details,
  exceptions, paths, URLs, and returned reason strings are never exposed.
  """

  alias LemonCore.BrowserProvider.LCUProbe

  @providers ~w(auto lcu relay local cdp browserbase browser_use firecrawl camofox controller hybrid)
  @auto ~w(lcu relay local)
  @timeout_ms 5_000
  @invalid "Invalid browser provider; set runtime.tools.browser.provider to a supported provider."
  @none "No browser provider is available; connect the LCU extension or relay, or install the local browser driver."
  @timeout "Browser provider check timed out; check the selected provider or choose another provider."
  @probe_failed "Browser provider availability could not be checked; check its configuration and runtime installation."

  @availability %{
    "lcu" => "LCU Chrome extension is connected through this installation's relay.",
    "relay" => "The configured browser relay is connected.",
    "local" => "The local browser executable and driver are available.",
    "cdp" => "The configured CDP browser is reachable.",
    "browserbase" => "Browserbase is configured and its driver is available.",
    "browser_use" => "Browser Use is configured and its driver is available.",
    "firecrawl" => "Firecrawl is configured and its driver is available.",
    "camofox" => "Camofox is configured and its driver is available.",
    "controller" => "The configured browser controller is connected.",
    "hybrid" => "The configured hybrid browser routes are available."
  }
  @unavailability %{
    "lcu" =>
      "LCU Chrome extension is not connected through its relay; check lcu browser status and reconnect the extension.",
    "relay" =>
      "Browser relay is not configured or connected; configure the relay and connect its browser extension.",
    "local" =>
      "Local browser executable or driver is unavailable; install Chrome/Chromium and run npm --prefix clients/lemon-browser-node install && npm --prefix clients/lemon-browser-node run build.",
    "cdp" => "CDP browser is unavailable; configure a reachable CDP endpoint.",
    "browserbase" => "Browserbase is unavailable; configure its credentials and browser driver.",
    "browser_use" => "Browser Use is unavailable; configure its credentials and browser driver.",
    "firecrawl" => "Firecrawl is unavailable; configure its credentials and browser driver.",
    "camofox" =>
      "Camofox is unavailable; configure a reachable Camofox endpoint and browser driver.",
    "controller" => "Browser controller is unavailable; configure and connect the controller.",
    "hybrid" =>
      "Hybrid browser is unavailable; configure available local and public browser routes."
  }

  @type resolution :: %{
          requested: String.t(),
          provider: String.t() | nil,
          reason: String.t(),
          checks: %{optional(String.t()) => %{available: boolean(), reason: String.t()}}
        }

  @doc "Supported configuration provider identifiers, including auto."
  def providers, do: @providers

  @spec resolve(keyword()) :: resolution()
  def resolve(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> LemonCore.Config.cached() end)
    browser = section(config, :browser)
    configured = value(browser, :provider)
    requested = Keyword.get(opts, :provider, if(is_nil(configured), do: "auto", else: configured))

    requested =
      if is_atom(requested) and not is_nil(requested),
        do: Atom.to_string(requested),
        else: requested

    if requested in @providers do
      candidates = if requested == "auto", do: @auto, else: [requested]
      resolve_candidates(candidates, requested, config, opts, %{})
    else
      %{requested: "invalid", provider: nil, reason: @invalid, checks: %{}}
    end
  rescue
    _ -> %{requested: "invalid", provider: nil, reason: @invalid, checks: %{}}
  catch
    _, _ -> %{requested: "invalid", provider: nil, reason: @invalid, checks: %{}}
  end

  @doc "Whether passive resolution selects the given provider."
  def selected?(id), do: resolve().provider == normalize_id(id)

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id), do: id

  defp resolve_candidates([], requested, _config, _opts, checks) do
    %{
      requested: requested,
      provider: nil,
      reason: @none <> " " <> auto_reason(checks),
      checks: checks
    }
  end

  defp resolve_candidates([provider | rest], requested, config, opts, checks) do
    {available, reason} = check(provider, config, opts)
    checks = Map.put(checks, provider, %{available: available, reason: reason})

    cond do
      available ->
        reason = if requested == "auto", do: auto_reason(checks), else: reason
        %{requested: requested, provider: provider, reason: reason, checks: checks}

      requested != "auto" ->
        %{requested: requested, provider: nil, reason: reason, checks: checks}

      true ->
        resolve_candidates(rest, requested, config, opts, checks)
    end
  end

  defp auto_reason(checks) do
    labels = %{"lcu" => "LCU", "relay" => "Relay", "local" => "Local"}

    @auto
    |> Enum.filter(&Map.has_key?(checks, &1))
    |> Enum.map_join(" ", fn provider ->
      check = Map.fetch!(checks, provider)
      outcome = if check.available, do: "selected", else: "not selected"
      "#{Map.fetch!(labels, provider)} #{outcome}: #{check.reason}"
    end)
  end

  defp check(provider, config, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)
    timeout = if is_integer(timeout) and timeout > 0, do: timeout, else: @timeout_ms

    result = bounded(fn -> probe(provider, config, opts, timeout) end, timeout)

    case result do
      :available -> {true, Map.fetch!(@availability, provider)}
      {:lcu_reason, true, reason} -> {true, reason}
      {:lcu_reason, false, reason} -> {false, reason}
      :unavailable -> {false, Map.fetch!(@unavailability, provider)}
      :timeout -> {false, @timeout}
      _ -> {false, @probe_failed}
    end
  end

  defp probe("lcu", config, opts, timeout) do
    callback =
      Keyword.get(opts, :lcu_probe, Application.get_env(:lemon_core, :browser_provider_lcu_probe))

    if is_nil(callback) do
      # Two bounded subprocesses fit inside the overall callback deadline.
      result =
        LCUProbe.available?(
          computer_use: section(config, :computer_use),
          timeout_ms: max(div(timeout, 3), 1)
        )

      case result do
        {:ok, reason} -> {:lcu_reason, true, reason}
        {:error, reason} -> {:lcu_reason, false, reason}
      end
    else
      callback.() |> classify()
    end
  end

  defp probe(provider, _config, opts, _timeout) do
    callback =
      Keyword.get(opts, :probe, Application.get_env(:lemon_core, :browser_provider_probe))

    result =
      cond do
        is_function(callback, 1) ->
          callback.(provider)

        is_atom(callback) and Code.ensure_loaded?(callback) and
            function_exported?(callback, :available?, 1) ->
          callback.available?(provider)

        true ->
          :invalid
      end

    classify(result)
  end

  defp classify({:ok, _}), do: :available
  defp classify({:error, _}), do: :unavailable
  defp classify(_), do: :failed

  defp bounded(fun, timeout) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            _ -> :failed
          catch
            _, _ -> :failed
          end

        send(caller, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        :failed
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end

  defp section(config, name) do
    tools =
      value(config, :tools) || value(value(config, :agent), :tools) ||
        value(value(config, :runtime), :tools)

    cond do
      is_map(tools) -> value(tools, name) || %{}
      is_map(value(config, name)) -> value(config, name)
      name == :browser and is_map(config) -> config
      true -> %{}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil
end
