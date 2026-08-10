defmodule LemonCore.Secrets.KeyProvider do
  @moduledoc """
  Behaviour for master key providers.

  A provider knows how to read (and optionally write) the encoded master key
  from one storage location: the macOS Keychain, an environment variable, a
  file on disk, or anything a host application plugs in.

  `LemonCore.Secrets.MasterKey` walks the configured providers in order and
  uses the first one that yields usable key material.

  ## Configuration

      config :lemon_core, LemonCore.Secrets,
        key_providers: [:keychain, :env, :file],
        key_file: "~/.lemon/secrets_master_key",
        env_var: "LEMON_SECRETS_MASTER_KEY"

  `:keychain`, `:env` and `:file` are shorthands for the built-in providers in
  `LemonCore.Secrets.KeyProvider.*`; any other atom is treated as a module name
  implementing this behaviour. Every setting can also be overridden per call by
  passing the same key in the options given to `LemonCore.Secrets` functions.

  ## Callbacks

  `c:fetch/1` returns the *encoded* key material (usually base64), not the raw
  key — decoding and validation happen in `LemonCore.Secrets.MasterKey`.

  Providers signal "nothing stored here, try the next one" with `{:error, :missing}`
  and "this backend does not exist on this machine" with `{:error, :unavailable}`.
  Any other error is treated as a real failure and reported once the chain is
  exhausted.
  """

  require Logger

  @type opts :: keyword()

  @doc "Short name for the provider, used as the `source` in resolve results."
  @callback name() :: atom()

  @doc "Whether this provider can be used on this machine."
  @callback available?(opts()) :: boolean()

  @doc "Reads the encoded master key."
  @callback fetch(opts()) :: {:ok, String.t()} | {:error, term()}

  @doc "Writes the encoded master key. Used by `LemonCore.Secrets.MasterKey.init/1`."
  @callback put(String.t(), opts()) :: :ok | {:error, term()}

  @doc """
  What to do when this provider holds unusable key material.

  `:halt` (the default) reports the error immediately — an explicitly
  configured but broken key is a user error worth surfacing. `:continue` moves
  on to the next provider, which is what the keychain does so that a stale
  entry cannot lock you out.
  """
  @callback on_invalid() :: :halt | :continue

  @optional_callbacks available?: 1, put: 2, on_invalid: 0

  @builtin %{
    keychain: __MODULE__.Keychain,
    env: __MODULE__.Env,
    file: __MODULE__.File
  }

  @default_order [:keychain, :env, :file]
  @default_env_var "LEMON_SECRETS_MASTER_KEY"
  @default_key_file_segments [".lemon", "secrets_master_key"]

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonCore.Secrets.KeyProvider

      @impl true
      def available?(_opts), do: true

      @impl true
      def on_invalid, do: :halt

      @impl true
      def put(_value, _opts), do: {:error, :unavailable}

      defoverridable available?: 1, on_invalid: 0, put: 2
    end
  end

  @spec default_order() :: [atom()]
  def default_order, do: @default_order

  @doc """
  Returns the provider modules to try, in order.

  Reads `:key_providers` from `opts` first, then from app env, falling back to
  the historical order (keychain, then env var, then key file).
  """
  @spec order(opts()) :: [module()]
  def order(opts \\ []) do
    opts
    |> option(:key_providers, @default_order)
    |> List.wrap()
    |> Enum.map(&translate/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec name(module()) :: atom()
  def name(provider) do
    if exports?(provider, :name, 0) do
      provider.name()
    else
      provider
    end
  end

  @spec available?(module(), opts()) :: boolean()
  def available?(provider, opts) do
    if exports?(provider, :available?, 1) do
      provider.available?(opts)
    else
      true
    end
  end

  @spec on_invalid(module()) :: :halt | :continue
  def on_invalid(provider) do
    if exports?(provider, :on_invalid, 0) do
      provider.on_invalid()
    else
      :halt
    end
  end

  @spec supports_put?(module()) :: boolean()
  def supports_put?(provider), do: exports?(provider, :put, 2)

  @spec exports?(module(), atom(), arity()) :: boolean()
  def exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  @doc """
  Looks a setting up in `opts`, then in `config :lemon_core, LemonCore.Secrets`.
  """
  @spec option(opts(), atom(), term()) :: term()
  def option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(settings(), key, default)
    end
  end

  @spec env_var(opts()) :: String.t()
  def env_var(opts \\ []), do: option(opts, :env_var, @default_env_var)

  @spec env_getter(opts()) :: (String.t() -> String.t() | nil)
  def env_getter(opts), do: Keyword.get(opts, :env_getter, &System.get_env/1)

  @doc """
  Absolute path of the master key file, or `nil` when it cannot be determined.

  Defaults to `~/.lemon/secrets_master_key`; `:key_file` (opts or app env)
  overrides it and may itself start with `~`.
  """
  @spec key_file(opts()) :: Path.t() | nil
  def key_file(opts) do
    case option(opts, :key_file, nil) do
      path when is_binary(path) and path != "" -> expand(path, opts)
      _ -> default_key_file(opts)
    end
  end

  @spec home_dir(opts()) :: String.t() | nil
  def home_dir(opts) do
    case Keyword.get(opts, :home_dir) || env_getter(opts).("HOME") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp settings, do: Application.get_env(:lemon_core, LemonCore.Secrets, [])

  defp translate(name) when is_atom(name) do
    case Map.fetch(@builtin, name) do
      {:ok, module} ->
        module

      :error ->
        if Code.ensure_loaded?(name) do
          name
        else
          Logger.warning("Ignoring unknown secrets key provider: #{inspect(name)}")
          nil
        end
    end
  end

  defp translate(other) do
    Logger.warning("Ignoring invalid secrets key provider: #{inspect(other)}")
    nil
  end

  defp default_key_file(opts) do
    case home_dir(opts) do
      nil -> nil
      home -> Path.join([home | @default_key_file_segments])
    end
  end

  # `~` expands against the caller-visible home (`:home_dir` or the injected
  # env getter), never `System.user_home!/0`: a caller that scopes HOME must
  # not end up pointing at the real key file.
  defp expand(path, opts) do
    case Path.split(path) do
      ["~" | rest] ->
        case home_dir(opts) do
          nil -> nil
          home -> Path.join([home | rest])
        end

      _ ->
        Path.expand(path)
    end
  end
end
