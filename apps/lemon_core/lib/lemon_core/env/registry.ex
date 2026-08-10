defmodule LemonCore.Env.Registry do
  @moduledoc """
  Contract for a module that declares environment variables.

  `LemonCore.Env` is the framework: typing, aliases, defaults, resolution and
  reporting. The *declarations* belong to whichever app reads the variable, so
  each app ships its own registry module and the runtime lists them:

      config :lemon_core, :env_registries, [
        LemonCore.Env.Declarations,
        LemonGateway.Env,
        LemonSimUi.Env
      ]

  `LemonCore.Env.all_declared/0` aggregates the listed modules, skipping any
  that are not loaded — so a build containing only some of the umbrella's apps
  reports exactly the variables its code can actually read.

  ## Implementing

  The contract is structural: a registry is any module exporting
  `declarations/0` that returns a list of `t:LemonCore.Env.declaration/0` maps.
  Apps that depend on `lemon_core` get compile-time validation from the macro:

      defmodule MyApp.Env do
        use LemonCore.Env.Registry

        @declarations [
          %{
            name: :my_app_timeout_ms,
            env_var: "MY_APP_TIMEOUT_MS",
            aliases: [],
            type: :integer,
            default: 5_000,
            doc: "How long MyApp waits before giving up.",
            secret?: false,
            required?: false,
            area: :my_app,
            apps: [:my_app]
          }
        ]
      end

  Apps that must not depend on `lemon_core` — `ai` is the one in this umbrella —
  simply define `declarations/0` by hand; the aggregate treats them the same.
  """

  @type declaration :: LemonCore.Env.declaration()

  @callback declarations() :: [declaration()]

  @required_keys [
    :name,
    :env_var,
    :aliases,
    :type,
    :default,
    :doc,
    :secret?,
    :required?,
    :area,
    :apps
  ]

  @types [:string, :integer, :float, :boolean, :list, :bytes]

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonCore.Env.Registry
      @before_compile LemonCore.Env.Registry
    end
  end

  defmacro __before_compile__(env) do
    declarations = Module.get_attribute(env.module, :declarations) || []
    LemonCore.Env.Registry.validate!(declarations, env.module)

    quote do
      @impl LemonCore.Env.Registry
      @spec declarations() :: [LemonCore.Env.Registry.declaration()]
      def declarations, do: @declarations
    end
  end

  @doc """
  Validate a declaration list, raising with the offending entry.

  Runs at compile time for registries using the macro; exposed so tooling and
  tests can check hand-written registries too.
  """
  @spec validate!([declaration()], module()) :: :ok
  def validate!(declarations, module) do
    unless is_list(declarations) do
      raise ArgumentError, "#{inspect(module)} @declarations must be a list"
    end

    Enum.each(declarations, &validate_one!(&1, module))

    duplicates =
      declarations
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)} declares duplicate names: #{inspect(duplicates)}"
    end

    :ok
  end

  defp validate_one!(decl, module) when is_map(decl) do
    missing = Enum.reject(@required_keys, &Map.has_key?(decl, &1))

    if missing != [] do
      raise ArgumentError,
            "#{inspect(module)} declaration #{inspect(Map.get(decl, :name))} is missing keys: " <>
              inspect(missing)
    end

    unless decl.type in @types do
      raise ArgumentError,
            "#{inspect(module)} declaration #{inspect(decl.name)} has unknown type " <>
              "#{inspect(decl.type)} (expected one of #{inspect(@types)})"
    end

    unless is_atom(decl.name) and is_binary(decl.env_var) and is_list(decl.aliases) do
      raise ArgumentError,
            "#{inspect(module)} declaration #{inspect(decl.name)} has a malformed " <>
              ":name, :env_var, or :aliases"
    end

    :ok
  end

  defp validate_one!(other, module) do
    raise ArgumentError, "#{inspect(module)} declaration must be a map, got: #{inspect(other)}"
  end
end
