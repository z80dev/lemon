defmodule LemonControlPlane.Doctor.Checks.Listeners do
  @moduledoc """
  Doctor diagnostics for Lemon's network listener binds.

  HTTP listeners are inspected with `lsof` or `/proc/net/tcp{,6}` where available:
  `listeners.control_plane`, `listeners.node_gateway`, `listeners.web`,
  `listeners.sim_ui` and `listeners.a2a`. Otherwise their configured bind is
  reported explicitly as configured. Non-loopback binds warn; a bind alone
  cannot prove whether TLS or an encrypted overlay fronts it.

  `listeners.epmd` is observed, not configured: epmd outlives the BEAM, so a
  stale instance from before the loopback upgrade can still hold `*:4369`. The
  socket is classified from `lsof` or `/proc/net/tcp{,6}`; an address that
  cannot be classified is reported as unknown rather than assumed safe.

  `listeners.distribution` reports the configured `inet_dist_use_interface`.
  Without it the listener address is unknown — the node's own name never proves
  where distribution binds.

  Registered via `config :lemon_core, :doctor_checks`.
  """

  alias LemonControlPlane.Auth.Authorize
  alias LemonCore.Doctor.Check

  @default_control_port 4040
  @default_node_port 4044
  @default_web_port 4080
  @default_sim_port 4090
  @default_a2a_port 9901
  @default_loopback {127, 0, 0, 1}

  @doc "Runs all listener diagnostic checks."
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    [
      check_control_plane(opts),
      check_node_gateway(opts),
      check_web(opts),
      check_sim_ui(opts),
      check_a2a(opts),
      check_epmd(opts),
      check_distribution(opts)
    ]
  end

  # ---------------------------------------------------------------------------
  # Listener checks (private)
  # ---------------------------------------------------------------------------

  defp check_control_plane(opts) do
    ip =
      opts[:control_plane_ip] ||
        Application.get_env(:lemon_control_plane, :ip) ||
        parse_ip_env("LEMON_CONTROL_PLANE_BIND_IP") ||
        @default_loopback

    port =
      opts[:control_plane_port] ||
        Application.get_env(:lemon_control_plane, :port) ||
        parse_port_env("LEMON_CONTROL_PLANE_PORT") ||
        @default_control_port

    evaluate_listener("listeners.control_plane", "Control plane", ip, port, opts)
  end

  defp check_node_gateway(opts) do
    gw_opts = Application.get_env(:lemon_control_plane, :node_gateway, [])

    port =
      opts[:node_gateway_port] ||
        Keyword.get(gw_opts, :port) ||
        parse_port_env("LEMON_CONTROL_PLANE_NODE_PORT") ||
        @default_node_port

    ip =
      opts[:node_gateway_ip] ||
        Keyword.get(gw_opts, :ip) ||
        parse_ip_env("LEMON_CONTROL_PLANE_NODE_BIND_IP") ||
        @default_loopback

    if port == 0 do
      Check.pass("listeners.node_gateway", "Node gateway is disabled (port 0).")
    else
      evaluate_listener("listeners.node_gateway", "Node gateway", ip, port, opts)
    end
  end

  defp check_web(opts) do
    configured? =
      Keyword.get(opts, :web_configured, Code.ensure_loaded?(LemonWeb.Endpoint))

    if not configured? do
      Check.skip("listeners.web", "Web UI is not configured.")
    else
      endpoint_opts = Application.get_env(:lemon_web, LemonWeb.Endpoint, [])
      http_opts = Keyword.get(endpoint_opts, :http, [])

      ip =
        opts[:web_ip] ||
          Keyword.get(http_opts, :ip) ||
          parse_ip_env("LEMON_WEB_BIND_IP") ||
          @default_loopback

      port =
        opts[:web_port] ||
          Keyword.get(http_opts, :port) ||
          parse_port_env("LEMON_WEB_PORT") ||
          @default_web_port

      evaluate_listener("listeners.web", "Web UI", ip, port, opts)
    end
  end

  defp check_sim_ui(opts) do
    configured? =
      Keyword.get(opts, :sim_ui_configured, Code.ensure_loaded?(LemonSimUi.Endpoint))

    if not configured? do
      Check.skip("listeners.sim_ui", "Sim UI is not configured.")
    else
      endpoint_opts = Application.get_env(:lemon_sim_ui, LemonSimUi.Endpoint, [])
      http_opts = Keyword.get(endpoint_opts, :http, [])

      ip =
        opts[:sim_ui_ip] ||
          Keyword.get(http_opts, :ip) ||
          parse_ip_env("LEMON_SIM_UI_BIND_IP") ||
          @default_loopback

      port =
        opts[:sim_ui_port] ||
          Keyword.get(http_opts, :port) ||
          parse_port_env("LEMON_SIM_UI_PORT") ||
          @default_sim_port

      evaluate_listener("listeners.sim_ui", "Sim UI", ip, port, opts)
    end
  end

  defp check_a2a(opts) do
    enabled? =
      Keyword.get_lazy(opts, :a2a_enabled, fn ->
        Code.ensure_loaded?(LemonControlPlane.A2A.Config) and
          LemonControlPlane.A2A.Config.enabled?()
      end)

    if not enabled? do
      Check.skip("listeners.a2a", "A2A listener is disabled.")
    else
      {ip, port} =
        if Code.ensure_loaded?(LemonControlPlane.A2A.Config) do
          config = LemonControlPlane.A2A.Config.current()

          {opts[:a2a_ip] || LemonControlPlane.A2A.Config.bind_ip(config),
           opts[:a2a_port] || config.port}
        else
          {opts[:a2a_ip] || @default_loopback, opts[:a2a_port] || @default_a2a_port}
        end

      evaluate_listener("listeners.a2a", "A2A listener", ip, port, opts)
    end
  end

  defp check_epmd(opts) do
    status = Keyword.get_lazy(opts, :epmd_status, &probe_epmd/0)

    case status do
      :wildcard ->
        Check.warn(
          "listeners.epmd",
          "epmd listener is bound to all interfaces (*:4369), which a stale instance from before the upgrade keeps.",
          "Stop Lemon with `lemon stop`, then run `epmd -kill` (or restart your computer)."
        )

      {:non_loopback, address} ->
        Check.warn(
          "listeners.epmd",
          "epmd listener is bound to #{address}:4369; ensure TLS or an encrypted overlay protects this bind.",
          "Stop Lemon with `lemon stop`, then run `epmd -kill` (or restart your computer)."
        )

      :loopback ->
        Check.pass("listeners.epmd", "epmd listener is bound to loopback (127.0.0.1:4369).")

      :not_running ->
        Check.pass("listeners.epmd", "epmd is not running; nothing listens on port 4369.")

      :unknown ->
        Check.warn(
          "listeners.epmd",
          "epmd bind address could not be determined.",
          "Stop Lemon with `lemon stop`, then run `epmd -kill` (or restart your computer) so epmd restarts on ERL_EPMD_ADDRESS=127.0.0.1."
        )
    end
  end

  defp check_distribution(opts) do
    status = Keyword.get_lazy(opts, :distribution_status, &distribution_status/0)

    case status do
      {:configured, interface} ->
        if loopback_ip?(interface) do
          Check.pass(
            "listeners.distribution",
            "Erlang distribution is configured to bind #{format_ip(interface)} (inet_dist_use_interface)."
          )
        else
          Check.warn(
            "listeners.distribution",
            "Erlang distribution is configured to bind #{format_ip(interface)}; ensure TLS or an encrypted overlay protects this bind.",
            "Append `-kernel inet_dist_use_interface {127,0,0,1}` to ELIXIR_ERL_OPTIONS."
          )
        end

      :not_active ->
        Check.skip("listeners.distribution", "Erlang distribution is not active.")

      :unknown ->
        Check.warn(
          "listeners.distribution",
          "Erlang distribution is active, but no bind interface is configured, so its listener address is unknown.",
          "Append `-kernel inet_dist_use_interface {127,0,0,1}` to ELIXIR_ERL_OPTIONS."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp evaluate_listener(check_name, label, ip, port, opts) do
    formatted_ip = format_ip(ip)

    observed =
      case Keyword.fetch(opts, :observed_binds) do
        {:ok, binds} -> Map.get(binds, port, :unknown)
        :error -> probe_listener(port)
      end

    case observed do
      :wildcard ->
        exposed_listener(check_name, label, "*", port)

      {:non_loopback, address} ->
        exposed_listener(check_name, label, address, port)

      :loopback ->
        Check.pass(
          check_name,
          "#{label} listener is bound to loopback on port #{port} (configured #{formatted_ip})."
        )

      _ ->
        if loopback_ip?(ip) do
          Check.pass(
            check_name,
            "#{label} is configured to bind loopback (#{formatted_ip}:#{port})."
          )
        else
          Check.warn(
            check_name,
            "#{label} is configured to bind #{formatted_ip}:#{port}; ensure TLS or an encrypted overlay protects this bind.",
            "Bind to loopback (127.0.0.1) or place TLS or an encrypted overlay (such as Tailscale) in front."
          )
        end
    end
  end

  defp exposed_listener(check_name, label, address, port) do
    Check.warn(
      check_name,
      "#{label} listener is bound to #{address}:#{port}; ensure TLS or an encrypted overlay protects this bind.",
      "Use a loopback bind and restart Lemon, or protect this listener with TLS or an encrypted overlay."
    )
  end

  # epmd runs outside the BEAM, so its bind is observed, never inferred from
  # configuration. An address that cannot be classified is reported as unknown.
  defp probe_epmd do
    # A refused loopback connection cannot rule out an epmd bound only to a LAN
    # address. Inspect listening sockets first; unavailable inspection is unknown.
    probe_listener(4369)
  rescue
    _ -> :unknown
  end

  defp probe_listener(port) do
    cond do
      lsof = System.find_executable("lsof") -> classify_listener_lsof(lsof, port)
      File.exists?("/proc/net/tcp") -> classify_listener_proc(port)
      true -> :unknown
    end
  end

  defp classify_listener_lsof(lsof, port) do
    case System.cmd(lsof, ["-nP", "-a", "-iTCP:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
      {output, 0} ->
        addresses =
          ~r/(?:^|\s)(\*|\[[0-9a-fA-F:.]+\]|\d+\.\d+\.\d+\.\d+):\d+\b/
          |> Regex.scan(output)
          |> Enum.map(fn [_match, address] -> address end)

        if addresses == [], do: :unknown, else: classify_addresses(addresses)

      _ ->
        # lsof reports both "no matches" and failures as a non-zero exit, so the
        # bind stays unproven rather than being called safe.
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp classify_listener_proc(port) do
    hex_port = port |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")

    rows =
      ["/proc/net/tcp", "/proc/net/tcp6"]
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} -> String.split(content, "\n", trim: true)
          _ -> []
        end
      end)
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [_slot, local, _remote, "0A" | _rest] ->
            case String.split(local, ":") do
              [hex_address, ^hex_port] -> [hex_address]
              _ -> []
            end

          _ ->
            []
        end
      end)

    case rows do
      [] -> :unknown
      addresses -> addresses |> Enum.map(&decode_proc_address/1) |> classify_addresses()
    end
  rescue
    _ -> :unknown
  end

  # /proc rows hold the address as little-endian hex: 0100007F is 127.0.0.1 and
  # 00000000 is the wildcard. IPv6 rows use the same byte order in four groups.
  defp decode_proc_address(hex) when byte_size(hex) == 8 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<a, b, c, d>>} -> "#{d}.#{c}.#{b}.#{a}"
      _ -> nil
    end
  end

  defp decode_proc_address(hex) when byte_size(hex) == 32 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<0::128>>} -> "*"
      {:ok, <<0::96, 1, 0, 0, 0>>} -> "[::1]"
      {:ok, _other} -> nil
      _ -> nil
    end
  end

  defp decode_proc_address(_hex), do: nil

  defp classify_addresses(addresses) do
    cond do
      addresses == [] -> :not_running
      Enum.any?(addresses, &is_nil/1) -> :unknown
      Enum.any?(addresses, &wildcard_address?/1) -> :wildcard
      Enum.all?(addresses, &loopback_ip?(strip_brackets(&1))) -> :loopback
      true -> {:non_loopback, addresses |> Enum.reject(&loopback_ip?(strip_brackets(&1))) |> hd()}
    end
  end

  defp wildcard_address?(address), do: address in ["*", "0.0.0.0", "[::]", "::"]

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(address), do: address

  # The node's own name never proves where the distribution listener binds, so
  # only an explicitly configured interface is reported as a bind.
  defp distribution_status do
    case Application.get_env(:kernel, :inet_dist_use_interface) do
      nil -> if Node.alive?(), do: :unknown, else: :not_active
      interface -> {:configured, interface}
    end
  end

  defp loopback_ip?(:loopback), do: true
  defp loopback_ip?(:any), do: false
  defp loopback_ip?("127.0.0.1"), do: true
  defp loopback_ip?("::1"), do: true
  defp loopback_ip?("0.0.0.0"), do: false
  defp loopback_ip?("::"), do: false

  defp loopback_ip?(ip) when is_tuple(ip) do
    Authorize.loopback_address?(ip)
  end

  defp loopback_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> Authorize.loopback_address?(tuple)
      _ -> false
    end
  end

  defp loopback_ip?(_), do: false

  defp format_ip(:any), do: "0.0.0.0"
  defp format_ip(:loopback), do: "127.0.0.1"

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      chars -> List.to_string(chars)
    end
  end

  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(ip), do: to_string(ip)

  defp parse_ip_env(var) do
    case System.get_env(var) do
      nil ->
        nil

      val ->
        case :inet.parse_address(String.to_charlist(String.trim(val))) do
          {:ok, ip} -> ip
          _ -> val
        end
    end
  end

  defp parse_port_env(var) do
    case System.get_env(var) do
      nil ->
        nil

      val ->
        case Integer.parse(String.trim(val)) do
          {port, ""} when port > 0 and port <= 65_535 -> port
          _ -> nil
        end
    end
  end
end
