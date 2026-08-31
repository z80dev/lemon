defmodule LemonControlPlane.A2A.Config do
  @moduledoc """
  Resolution and validation for Lemon's `[gateway.a2a]` peer transport.

  Peer credentials are secret *names*, never literal tokens. Each peer may use
  one `token_secret` in both directions or separate inbound/outbound names.
  """

  @behaviour LemonCore.Config.Gateway.Channel

  alias LemonCore.Config.Validator
  alias LemonCore.Env

  @default_tools ~w(read read_skill search_memory session_search grep find ls webfetch websearch kanban peer)

  @impl true
  def id, do: :a2a

  @impl true
  def enabled?(configured) do
    Env.get(:lemon_gateway_enable_a2a, default: configured)
  end

  @impl true
  def resolve(section) when is_map(section) do
    %{
      host: Env.get(:lemon_a2a_host, default: value(section, "host", "127.0.0.1")),
      port: Env.get(:lemon_a2a_port, default: value(section, "port", 9901)),
      public_url: Env.get(:lemon_a2a_public_url, default: value(section, "public_url", nil)),
      name: value(section, "name", "Lemon"),
      description: value(section, "description", "A persistent Lemon agent available over A2A"),
      agent_id: value(section, "agent_id", "default"),
      skills: string_list(value(section, "skills", ["coordination", "coding"])),
      reply_timeout_ms:
        Env.get(:lemon_a2a_reply_timeout_ms,
          default: value(section, "reply_timeout_ms", 300_000)
        ),
      rate_limit_per_minute:
        Env.get(:lemon_a2a_rate_limit_per_minute,
          default: value(section, "rate_limit_per_minute", 60)
        ),
      max_context_turns:
        Env.get(:lemon_a2a_max_context_turns,
          default: value(section, "max_context_turns", 100)
        ),
      default_allow_tools: string_list(value(section, "default_allow_tools", @default_tools)),
      peers: normalize_peers(value(section, "peers", %{}))
    }
  end

  def resolve(_), do: resolve(%{})

  @impl true
  def validate(section, errors) when is_map(section) do
    errors
    |> Validator.validate_positive_integer(section.port, "gateway.a2a.port")
    |> Validator.validate_positive_integer(
      section.reply_timeout_ms,
      "gateway.a2a.reply_timeout_ms"
    )
    |> Validator.validate_positive_integer(
      section.rate_limit_per_minute,
      "gateway.a2a.rate_limit_per_minute"
    )
    |> Validator.validate_positive_integer(
      section.max_context_turns,
      "gateway.a2a.max_context_turns"
    )
    |> validate_remote_bind(section)
  end

  def validate(_, errors), do: ["gateway.a2a: must be a map" | errors]

  @doc "Returns the effective runtime configuration, with a test/application override."
  @spec current() :: map()
  def current do
    case Application.get_env(:lemon_control_plane, :a2a_config) do
      config when is_map(config) -> Map.merge(resolve(%{}), config)
      _ -> LemonCore.Config.load().gateway |> Map.get(:a2a, resolve(%{}))
    end
  end

  @doc "Whether the A2A listener is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:lemon_control_plane, :a2a_enabled) do
      enabled when is_boolean(enabled) -> enabled
      _ -> LemonCore.Config.load().gateway |> Map.get(:enable_a2a, false)
    end
  end

  @spec peer(binary()) :: map() | nil
  def peer(peer_id), do: current().peers |> Map.get(peer_id)

  @spec bind_ip(map()) :: :inet.ip_address()
  def bind_ip(config \\ current()) do
    case :inet.parse_address(String.to_charlist(config.host)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp normalize_peers(peers) when is_map(peers) do
    Map.new(peers, fn {id, peer} ->
      peer = if is_map(peer), do: peer, else: %{}

      {to_string(id),
       %{
         id: to_string(id),
         url: value(peer, "url", nil),
         agent_id: value(peer, "agent_id", "default"),
         token_secret: value(peer, "token_secret", nil),
         inbound_token_secret: value(peer, "inbound_token_secret", nil),
         outbound_token_secret: value(peer, "outbound_token_secret", nil),
         allow_tools: string_list(value(peer, "allow_tools", [])),
         capabilities: string_list(value(peer, "capabilities", [])),
         timeout_ms: value(peer, "timeout_ms", 300_000)
       }}
    end)
  end

  defp normalize_peers(_), do: %{}

  defp value(map, key, default) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  defp string_list(values) when is_list(values),
    do:
      values |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp string_list(_), do: []

  defp validate_remote_bind(errors, %{host: host, peers: peers}) do
    loopback? = host in ["127.0.0.1", "::1", "localhost"]

    protected? =
      Enum.any?(peers, fn {_id, peer} ->
        is_binary(peer.inbound_token_secret || peer.token_secret)
      end)

    if loopback? or protected? do
      errors
    else
      ["gateway.a2a.host: non-loopback listeners require an inbound peer token secret" | errors]
    end
  end
end
