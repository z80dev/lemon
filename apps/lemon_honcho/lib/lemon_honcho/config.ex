defmodule LemonHoncho.Config do
  @moduledoc """
  Resolved settings for the Honcho memory satellite.

  Every knob the integration has is gathered here, once, into a struct the rest
  of the app can pattern-match on. Nothing else in `lemon_honcho` reads the
  environment: the client takes a `t:t/0`, the session manager takes a `t:t/0`,
  and the tools take a `t:t/0`. That is what makes the app testable without
  touching process-wide state, and it is why `load/0` is cheap enough to call
  per turn rather than being cached behind an agent.

  ## Resolution order

  For each field: the environment variable declared in `LemonHoncho.Env`, then
  `Application.get_env(:lemon_honcho, key)`, then `[honcho]` in the global Lemon
  config, then the built-in default. `api_key_secret` references Lemon's encrypted
  secret store, never a plaintext TOML key. A value that is present but unusable
  is treated as absent and resolution continues to the next source.
  That rule matters more than it looks: this config is read on the way up in
  `LemonHoncho.Application`, so an operator typo that raised here would take
  the whole node down instead of quietly disabling one memory backend.

  ## Being configured is not the same as being enabled

  `enabled?` is the operator's switch and defaults to true, because the useful
  default for a satellite is "on if you gave it credentials". `configured?/1`
  is the question everything else asks: it is true only when the integration
  has somewhere to talk to (an API key or a base URL) *and* has not been
  switched off. An unconfigured Honcho registers no memory provider, context
  contributor or tools, so it adds neither search latency nor tool-schema tokens.
  """

  alias LemonCore.Config.Helpers

  @typedoc "How Honcho memory reaches the model."
  @type recall_mode :: :hybrid | :context | :tools

  @typedoc "What one Honcho session corresponds to on this machine."
  @type session_strategy :: :per_session | :per_directory | :per_repo | :global

  @typedoc "Reasoning budget Honcho spends answering a dialectic query."
  @type reasoning_level :: :minimal | :low | :medium | :high | :max

  @typedoc "Which side of a conversation each peer is asked to observe."
  @type observation_mode :: :directional | :unified

  @typedoc "Per-peer observation flags as Honcho's session API expects them."
  @type peer_flags :: %{observe_me: boolean(), observe_others: boolean()}

  @type t :: %__MODULE__{
          enabled?: boolean(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          environment: String.t(),
          workspace: String.t(),
          user_peer: String.t(),
          pin_user_peer: boolean(),
          user_peer_aliases: %{String.t() => String.t()},
          runtime_peer_prefix: String.t(),
          ai_peer: String.t(),
          timeout_ms: pos_integer(),
          recall_mode: recall_mode(),
          session_strategy: session_strategy(),
          context_cadence: pos_integer(),
          dialectic_cadence: pos_integer(),
          context_tokens: pos_integer() | nil,
          dialectic_max_chars: pos_integer(),
          reasoning_level: reasoning_level(),
          observation_mode: observation_mode(),
          save_messages?: boolean(),
          inject_in_subagents?: boolean(),
          first_turn_wait_ms: non_neg_integer(),
          message_max_chars: pos_integer()
        }

  defstruct enabled?: true,
            api_key: nil,
            base_url: nil,
            environment: "production",
            workspace: "lemon",
            user_peer: "user",
            pin_user_peer: false,
            user_peer_aliases: %{},
            runtime_peer_prefix: "",
            ai_peer: "lemon",
            timeout_ms: 30_000,
            recall_mode: :hybrid,
            session_strategy: :per_directory,
            context_cadence: 1,
            dialectic_cadence: 2,
            context_tokens: nil,
            dialectic_max_chars: 600,
            reasoning_level: :low,
            observation_mode: :directional,
            save_messages?: true,
            inject_in_subagents?: false,
            first_turn_wait_ms: 3_000,
            message_max_chars: 25_000

  @app :lemon_honcho
  @recall_modes [:hybrid, :context, :tools]
  @session_strategies [:per_session, :per_directory, :per_repo, :global]
  @reasoning_levels [:minimal, :low, :medium, :high, :max]
  @observation_modes [:directional, :unified]
  @fallback_user_peer "user"

  @doc """
  Builds the config from the environment, application env, global TOML and defaults.

  Never raises: an unusable value falls through to the next source, so the
  worst an operator typo can do is leave a field at its default.

  ## Examples

      iex> config = LemonHoncho.Config.load()
      iex> config.recall_mode in [:hybrid, :context, :tools]
      true
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    settings = settings(Keyword.get(opts, :config_path, LemonCore.Config.global_path()))
    resolve = &resolve(&1, &2, &3, &4, settings)
    enum = &enum(&1, &2, &3, &4, settings)

    %__MODULE__{
      enabled?: resolve.("LEMON_HONCHO_ENABLED", :enabled, &parse_bool/1, true),
      api_key: api_key(settings),
      base_url: resolve.("HONCHO_BASE_URL", :base_url, &parse_string/1, nil),
      environment: resolve.("HONCHO_ENVIRONMENT", :environment, &parse_string/1, "production"),
      workspace: resolve.("HONCHO_WORKSPACE", :workspace, &parse_string/1, "lemon"),
      user_peer: user_peer(settings),
      pin_user_peer: resolve.("LEMON_HONCHO_PIN_USER_PEER", :pin_user_peer, &parse_bool/1, false),
      user_peer_aliases:
        resolve.("LEMON_HONCHO_USER_PEER_ALIASES", :user_peer_aliases, &parse_aliases/1, %{}),
      runtime_peer_prefix:
        resolve.("LEMON_HONCHO_RUNTIME_PEER_PREFIX", :runtime_peer_prefix, &parse_prefix/1, ""),
      ai_peer: resolve.("HONCHO_AI_PEER", :ai_peer, &parse_string/1, "lemon"),
      timeout_ms: resolve.("HONCHO_TIMEOUT_MS", :timeout_ms, &parse_pos_int/1, 30_000),
      recall_mode: enum.(env(:recall_mode), :recall_mode, @recall_modes, :hybrid),
      session_strategy:
        enum.(env(:session_strategy), :session_strategy, @session_strategies, :per_directory),
      context_cadence: resolve.(env(:context_cadence), :context_cadence, &parse_pos_int/1, 1),
      dialectic_cadence:
        resolve.(env(:dialectic_cadence), :dialectic_cadence, &parse_pos_int/1, 2),
      context_tokens: resolve.(env(:context_tokens), :context_tokens, &parse_pos_int/1, nil),
      dialectic_max_chars:
        resolve.(env(:dialectic_max_chars), :dialectic_max_chars, &parse_pos_int/1, 600),
      reasoning_level: enum.(env(:reasoning_level), :reasoning_level, @reasoning_levels, :low),
      observation_mode:
        enum.(env(:observation_mode), :observation_mode, @observation_modes, :directional),
      save_messages?: resolve.(env(:save_messages), :save_messages, &parse_bool/1, true),
      inject_in_subagents?:
        resolve.(env(:inject_in_subagents), :inject_in_subagents, &parse_bool/1, false),
      first_turn_wait_ms:
        resolve.(env(:first_turn_wait_ms), :first_turn_wait_ms, &parse_non_neg_int/1, 3_000),
      message_max_chars:
        resolve.(env(:message_max_chars), :message_max_chars, &parse_pos_int/1, 25_000)
    }
  end

  @doc """
  Whether the integration has an endpoint to talk to and has not been disabled.

  An API key alone is enough (Honcho's hosted deployment is the default), and a
  base URL alone is enough (a self-hosted deployment may not require auth).
  Everything that would cost a caller latency — the memory provider, the
  context contributor — is registered only when this returns true.

  ## Examples

      iex> LemonHoncho.Config.configured?(%LemonHoncho.Config{api_key: "sk-test"})
      true

      iex> LemonHoncho.Config.configured?(%LemonHoncho.Config{})
      false
  """
  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{} = config) do
    config.enabled? and (present?(config.api_key) or present?(config.base_url))
  end

  @doc """
  Expands `observation_mode` into the per-peer flags Honcho's session API takes.

  `:directional` is the default and the richer of the two: both peers observe
  themselves and each other, so Honcho builds a theory of the user *and* a
  theory of how the assistant behaves. `:unified` collapses that into a single
  model of the user — the human peer observes only itself, the assistant peer
  only the other side — which is cheaper and is what an operator wants when a
  workspace is shared by many assistants.

  ## Examples

      iex> LemonHoncho.Config.observation_flags(%LemonHoncho.Config{observation_mode: :unified})
      %{
        user: %{observe_me: true, observe_others: false},
        ai: %{observe_me: false, observe_others: true}
      }
  """
  @spec observation_flags(t()) :: %{user: peer_flags(), ai: peer_flags()}
  def observation_flags(%__MODULE__{observation_mode: :unified}) do
    %{
      user: %{observe_me: true, observe_others: false},
      ai: %{observe_me: false, observe_others: true}
    }
  end

  def observation_flags(%__MODULE__{}) do
    %{
      user: %{observe_me: true, observe_others: true},
      ai: %{observe_me: true, observe_others: true}
    }
  end

  # The `LEMON_HONCHO_` prefix is spelled once so a rename cannot drift between
  # here and LemonHoncho.Env.
  defp env(key), do: "LEMON_HONCHO_" <> String.upcase(Atom.to_string(key))

  defp settings(path) do
    case Toml.decode_file(path) do
      {:ok, %{"honcho" => settings}} when is_map(settings) -> settings
      _ -> %{}
    end
  end

  defp api_key(settings) do
    case resolve("HONCHO_API_KEY", :api_key, &parse_string/1, nil, %{}) do
      nil ->
        with {:ok, name} <- parse_string(settings["api_key_secret"]),
             {:ok, value} <- LemonCore.Secrets.get(name) do
          value
        else
          _ -> nil
        end

      value ->
        value
    end
  end

  # Peer ids address a durable record in someone's Honcho workspace, so they are
  # sanitized rather than passed through: a login containing "@" or "." would
  # otherwise create a peer that is awkward to address later. $USER is the
  # default because the person at the keyboard is who the memory is about.
  defp user_peer(settings) do
    resolved =
      resolve("HONCHO_PEER", :user_peer, &parse_string/1, nil, settings) ||
        System.get_env("USER") ||
        @fallback_user_peer

    case sanitize_peer(resolved) do
      "" -> @fallback_user_peer
      peer -> peer
    end
  end

  defp sanitize_peer(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "_")
    |> String.trim("_")
  end

  defp enum(env_var, app_key, allowed, default, settings) do
    resolve(env_var, app_key, &parse_enum(&1, allowed), default, settings)
  end

  # Invalid values fall through rather than preventing the satellite from booting.
  defp resolve(env_var, app_key, parser, default, settings) do
    with :error <- parse_source(Helpers.get_env(env_var), parser),
         :error <- parse_source(Application.get_env(@app, app_key), parser),
         :error <- parse_source(settings[Atom.to_string(app_key)], parser) do
      default
    else
      {:ok, value} -> value
    end
  end

  defp parse_source(nil, _parser), do: :error
  defp parse_source(raw, parser), do: parser.(raw)

  defp parse_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_string(value) when is_atom(value), do: parse_string(Atom.to_string(value))
  defp parse_string(_value), do: :error

  defp parse_prefix(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp parse_prefix(_), do: :error

  defp parse_aliases(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, aliases} when is_map(aliases) -> parse_aliases(aliases)
      _ -> :error
    end
  end

  defp parse_aliases(value) when is_map(value) do
    if Enum.all?(value, fn {key, peer} ->
         is_binary(key) and key != "" and is_binary(peer) and
           Regex.match?(~r/^[A-Za-z0-9_-]{1,512}$/, peer)
       end),
       do: {:ok, value},
       else: :error
  end

  defp parse_aliases(_), do: :error

  defp parse_bool(value) when is_boolean(value), do: {:ok, value}

  defp parse_bool(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      truthy when truthy in ~w(true 1 yes on) -> {:ok, true}
      falsy when falsy in ~w(false 0 no off) -> {:ok, false}
      _other -> :error
    end
  end

  defp parse_bool(_value), do: :error

  defp parse_pos_int(value) do
    case parse_int(value) do
      {:ok, int} when int > 0 -> {:ok, int}
      _other -> :error
    end
  end

  defp parse_non_neg_int(value) do
    case parse_int(value) do
      {:ok, int} when int >= 0 -> {:ok, int}
      _other -> :error
    end
  end

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp parse_int(_value), do: :error

  # Enum values are accepted in the spelling operators actually type:
  # "per-directory" and "per_directory" and :per_directory all land on the same
  # atom, and anything else is rejected rather than converted to a new atom.
  defp parse_enum(value, allowed) when is_atom(value) do
    parse_enum(Atom.to_string(value), allowed)
  end

  defp parse_enum(value, allowed) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    case Enum.find(allowed, &(Atom.to_string(&1) == normalized)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp parse_enum(_value, _allowed), do: :error

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
