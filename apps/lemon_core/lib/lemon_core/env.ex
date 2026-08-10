defmodule LemonCore.Env do
  @moduledoc """
  Typed, declarative environment-variable registry for Lemon.

  This module is the *framework*: typing, aliases, defaults, resolution and
  redaction-safe reporting. The declarations themselves belong to whichever
  app reads the variable — each app ships a `LemonCore.Env.Registry` module
  and the runtime lists them under `:env_registries` (see `registries/0`).
  `all_declared/0` aggregates whatever is loaded, so a build with only some
  of the umbrella's apps reports exactly the variables its code can read.

  It does not yet replace the scattered `System.get_env/1` call sites across
  the umbrella -- callers migrate to `LemonCore.Env.get/2` in a later phase.
  Until then, this registry is the living documentation: see
  `docs/config-registry.md` for the reference table.

  ## Usage

      # Look up a declared variable by name, applying its declared type,
      # aliases, and default:
      LemonCore.Env.get(:lemon_arena_poker_models)
      #=> ["anthropic:claude-sonnet-4-20250514", "openai:gpt-5"]

      LemonCore.Env.get(:lemon_web_port)
      #=> 4080

      # Raw (undeclared) typed reads, e.g. for one-off/local variables that
      # don't warrant a registry entry:
      LemonCore.Env.int("SOME_TIMEOUT_MS", 5_000)
      LemonCore.Env.bool("SOME_FLAG", false)
      LemonCore.Env.list("SOME_HOSTS")

      # Every declared variable, for tooling (e.g. `mix lemon.doctor`) or
      # generating docs:
      LemonCore.Env.all_declared()

  ## Declaration shape

  Each declared variable is a map with:

    * `:name` - atom key used with `get/2`, e.g. `:lemon_web_port`
    * `:env_var` - the canonical environment variable name
    * `:aliases` - legacy/fallback environment variable names checked (in
      order) if `:env_var` is unset. Existing grandfathered non-conforming
      names live here rather than as the primary `:env_var` -- see the
      naming convention section of `docs/config-registry.md`.
    * `:type` - one of `:string`, `:integer`, `:float`, `:boolean`, `:list`,
      `:bytes` (parsed via `LemonCore.Config.Helpers.get_env_bytes/2`)
    * `:default` - value used when nothing resolves from the environment
    * `:doc` - one-line human-readable description
    * `:secret?` - whether the *value* should be redacted in any reporting
      surface (see `LemonCore.Env.Resolved`)
    * `:required?` - reserved for call-site opt-in; `get/2` also accepts a
      per-call `required: true` option independent of this flag
    * `:area` - a coarse grouping used to organize `docs/config-registry.md`
    * `:apps` - umbrella app(s) that read this variable today

  ## Type casting

  Casting is delegated to `LemonCore.Config.Helpers`, the umbrella's
  existing env-parsing toolkit, so behavior (bool truthy/falsy spellings,
  duration/byte-size suffixes, list delimiters) stays consistent with
  every other config reader in the codebase.
  """

  alias LemonCore.Config.Helpers

  @type var_type :: :string | :integer | :float | :boolean | :list | :bytes

  @type declaration :: %{
          name: atom(),
          env_var: String.t(),
          aliases: [String.t()],
          type: var_type(),
          default: term(),
          doc: String.t(),
          secret?: boolean(),
          required?: boolean(),
          area: atom(),
          apps: [atom()]
        }

  @doc """
  Returns every declared environment variable (name, env var, type,
  default, doc, secret?/required? flags, area, and owning apps).

  This is the source of truth behind `docs/config-registry.md` and is
  intended for tooling (e.g. a future `mix lemon.doctor` check) as well as
  interactive exploration.
  """
  @spec all_declared() :: [declaration()]
  def all_declared do
    registries()
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.flat_map(& &1.declarations())
  end

  @doc """
  The registry modules consulted by `all_declared/0`, in order.

  Defaults to lemon_core's own declarations so the library works unconfigured;
  the reference runtime lists every app's registry in `config/config.exs`.
  Modules that are not loaded are skipped rather than raising.
  """
  @spec registries() :: [module()]
  def registries do
    Application.get_env(:lemon_core, :env_registries, [LemonCore.Env.Declarations])
  end

  @doc """
  Returns the declarations for a single `:area` (e.g. `:agent`, `:gateway`,
  `:arena`). See `all_declared/0` for the full list of areas in use.
  """
  @spec by_area(atom()) :: [declaration()]
  def by_area(area), do: Enum.filter(all_declared(), &(&1.area == area))

  @doc """
  Returns the declaration for `name`, or `nil` if nothing is declared under
  that name.
  """
  @spec describe(atom()) :: declaration() | nil
  def describe(name), do: Enum.find(all_declared(), &(&1.name == name))

  @doc """
  Resolves a declared environment variable by its registry name.

  Resolution order: `env_var` -> each of `aliases` (in declared order) ->
  `opts[:default]` -> the declaration's own `:default`. The resolved value
  is cast according to the declaration's `:type`.

  ## Options

    * `:default` - override the declaration's default for this call
    * `:required` - if true (or if the declaration has `required?: true`),
      raises `ArgumentError` when the value resolves to `nil`/`""`/`[]`

  ## Examples

      iex> LemonCore.Env.get(:lemon_web_port)
      4080

      iex> System.put_env("LEMON_ARENA_POKER_MODELS", "anthropic:claude-sonnet-4-20250514")
      iex> LemonCore.Env.get(:lemon_arena_poker_models)
      ["anthropic:claude-sonnet-4-20250514"]
  """
  @spec get(atom(), keyword()) :: term()
  def get(name, opts \\ []) do
    decl = declaration!(name)
    default = Keyword.get(opts, :default, decl.default)

    value =
      case find_set_env_var(decl) do
        nil -> default
        env_var -> cast(decl.type, env_var, default)
      end

    required? = Keyword.get(opts, :required, decl.required?)

    if required? and blank?(value) do
      raise ArgumentError,
            "Missing required environment variable: #{decl.env_var}#{alias_hint(decl)} " <>
              "(declared as #{inspect(decl.name)})"
    end

    value
  end

  @doc """
  Returns a redaction-safe snapshot of every declared variable's *current*
  resolved value, tagged with its resolution `:source` (`:env`, `:alias`,
  or `:default`). Secret-flagged values are redacted whenever the snapshot
  is inspected/logged (see `LemonCore.Env.Resolved`).
  """
  @spec snapshot() :: [LemonCore.Env.Resolved.t()]
  def snapshot do
    Enum.map(all_declared(), fn decl ->
      {value, source} = resolve_with_source(decl)

      %LemonCore.Env.Resolved{
        name: decl.name,
        env_var: decl.env_var,
        value: value,
        source: source,
        secret?: decl.secret?
      }
    end)
  end

  @doc """
  Gets an optional raw (undeclared) string environment variable.
  """
  @spec string(String.t(), String.t() | nil) :: String.t() | nil
  def string(env_var, default \\ nil), do: Helpers.get_env(env_var, default)

  @doc """
  Gets a raw (undeclared) integer environment variable.
  """
  @spec int(String.t(), integer()) :: integer()
  def int(env_var, default \\ 0), do: Helpers.get_env_int(env_var, default)

  @doc """
  Gets a raw (undeclared) boolean environment variable.
  """
  @spec bool(String.t(), boolean()) :: boolean()
  def bool(env_var, default \\ false), do: Helpers.get_env_bool(env_var, default)

  @doc """
  Gets a raw (undeclared) list environment variable, split on `delimiter`.
  """
  @spec list(String.t(), String.t()) :: [String.t()]
  def list(env_var, delimiter \\ ","), do: Helpers.get_env_list(env_var, delimiter)

  # -- Internal ---------------------------------------------------------------

  defp declaration!(name) do
    case describe(name) do
      nil ->
        raise ArgumentError,
              "LemonCore.Env: no variable declared as #{inspect(name)}. " <>
                "Declare it in your app's LemonCore.Env.Registry module (and list " <>
                "that module under :env_registries), or use the raw string/2, " <>
                "int/2, bool/2, list/2 helpers for one-off variables."

      decl ->
        decl
    end
  end

  defp find_set_env_var(decl) do
    Enum.find([decl.env_var | decl.aliases], fn candidate -> Helpers.get_env(candidate) != nil end)
  end

  defp resolve_with_source(decl) do
    case find_set_env_var(decl) do
      nil -> {decl.default, :default}
      env_var when env_var == decl.env_var -> {cast(decl.type, env_var, decl.default), :env}
      env_var -> {cast(decl.type, env_var, decl.default), :alias}
    end
  end

  defp cast(:string, env_var, default), do: Helpers.get_env(env_var, default)
  defp cast(:integer, env_var, default), do: Helpers.get_env_int(env_var, default)
  defp cast(:float, env_var, default), do: Helpers.get_env_float(env_var, default)
  defp cast(:boolean, env_var, default), do: Helpers.get_env_bool(env_var, default)
  defp cast(:list, env_var, _default), do: Helpers.get_env_list(env_var)
  defp cast(:bytes, env_var, default), do: Helpers.get_env_bytes(env_var, default)

  defp alias_hint(%{aliases: []}), do: ""

  defp alias_hint(%{aliases: aliases}),
    do: " (also checked: #{Enum.join(aliases, ", ")})"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false
end
