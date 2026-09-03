defmodule LemonPlatformTest do
  @moduledoc """
  Contract-test kit for Lemon's extension behaviours.

  Lemon is extended by implementing behaviours: a storage backend, a channel
  adapter, or a memory provider. Each behaviour has rules that the `@callback`
  declarations cannot express — what a callback
  may return when the thing it talks to is unavailable, which callbacks must be
  pure, what must happen instead of raising on hostile input, and what the
  platform's registries expect when your module registers itself at runtime.

  This package turns those rules into runnable ExUnit suites. Point one at your
  implementation and it runs the same compliance tests the built-in
  implementations are held to:

      defmodule MyApp.BackendComplianceTest do
        use LemonPlatformTest.BackendCase,
          async: true,
          backend: MyApp.RedisBackend,
          backend_opts: [url: "redis://localhost:6379/15"]
      end

  That is the whole integration. The suite contributes its own tests; you can
  add your own tests to the same module alongside them.

  ## The three suites

  | Behaviour | Case template | What you are building |
  |---|---|---|
  | `LemonCore.Store.Backend` | `LemonPlatformTest.BackendCase` | storage for the platform's key/value store |
  | `LemonChannels.Plugin` | `LemonPlatformTest.PluginCase` | a chat/messaging channel (Telegram, Discord, …) |
  | `LemonMemory.Provider` | `LemonPlatformTest.ProviderCase` | a searchable long-term memory source |

  Each case template's moduledoc is the reference guide for its behaviour: the
  contract in prose, a minimal worked implementation, and every option the suite
  accepts. Start there.

  ## What these suites are and are not

  They test the **contract**, never an implementation's internals. A suite only
  ever calls the behaviour's callbacks and the platform's public registration
  APIs, so it is equally valid against a built-in implementation and against
  yours. If a suite fails, either your implementation breaks a rule the platform
  relies on, or the rule is wrong — both are worth knowing, and the second is
  worth an issue.

  They are also deliberately **safe by default**: no suite will make a network
  call, deliver a real message, or invoke a runner unless you opt in by passing
  a probe (see `LemonPlatformTest.PluginCase` `:deliver_probe`). Compliance
  suites that accidentally post to your production Telegram bot are worse than
  no suite.

  ## Options common to all three

    * `:async` — forwarded to `use ExUnit.Case`. Suites that exercise a global
      platform registry (`:registry` option) must run with `async: false`.
    * `:registry` — most suites can round-trip your module through the
      platform's registry for that behaviour. This proves the part third-party
      code gets wrong most often: the module works standalone but the platform
      cannot discover it. Enabled by default where it applies; requires the
      relevant OTP application to be started in your `test_helper.exs`.

  Every option must be a literal at the `use` site (a module alias, a keyword
  list, a `{Module, :function}` tuple) — they are read while your test module
  compiles.

  ## Helper API

  The functions in this module are what the suites use to introspect a
  behaviour. They are public because they are occasionally useful in your own
  tests.
  """

  @doc """
  Returns true when `module` declares `behaviour` via `@behaviour`.

  Declaring the behaviour is not merely decorative: it is what makes the
  compiler check your callback names and arities, and it is how tooling
  discovers implementations.

      iex> LemonPlatformTest.declares_behaviour?(LemonCore.Store.EtsBackend, LemonCore.Store.Backend)
      true
  """
  @spec declares_behaviour?(module(), module()) :: boolean()
  def declares_behaviour?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end

  @doc """
  Returns `behaviour`'s callbacks split into required and optional.

      iex> %{optional: optional} = LemonPlatformTest.callbacks(LemonCore.Store.Backend)
      iex> Enum.sort(optional)
      [compare_and_delete_many: 2, list_recent: 3, ping: 1]
  """
  @spec callbacks(module()) :: %{required: [{atom(), arity()}], optional: [{atom(), arity()}]}
  def callbacks(behaviour) do
    Code.ensure_loaded?(behaviour) ||
      raise ArgumentError, "unknown behaviour: #{inspect(behaviour)}"

    all = behaviour.behaviour_info(:callbacks)
    optional = behaviour.behaviour_info(:optional_callbacks)

    %{required: all -- optional, optional: optional}
  end

  @doc """
  Returns the required callbacks of `behaviour` that `module` does not export.

  An empty list means the module is implementable-complete. Note that a module
  can export every callback and still fail its compliance suite — exporting is
  the floor, not the contract.
  """
  @spec missing_callbacks(module(), module()) :: [{atom(), arity()}]
  def missing_callbacks(module, behaviour) do
    Code.ensure_loaded?(module)

    behaviour
    |> callbacks()
    |> Map.fetch!(:required)
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  @doc """
  Resolves a suite option that may be a literal value or a `{Module, :function}`
  supplier invoked with the test context.

  Suites use this so options that need per-test data (a temp directory, a fresh
  payload) can be computed instead of hardcoded:

      use LemonPlatformTest.BackendCase,
        backend: MyBackend,
        backend_opts: {__MODULE__, :backend_opts}

      def backend_opts(context), do: [path: context.tmp_dir]
  """
  @spec resolve({module(), atom()} | term(), map()) :: term()
  def resolve({module, function}, context) when is_atom(module) and is_atom(function) do
    apply(module, function, [context])
  end

  def resolve(value, _context), do: value

  @doc """
  Compile-time assertion that the platform dependency a case template needs is
  present, with a pointed error when it is not.

  The platform apps are `optional: true` dependencies of `:lemon_platform_test`
  so that a consumer compiles only the one their case exercises. Each case
  template calls this from its `using` macro, so the failure surfaces when the
  *consumer's* test module compiles — naming the missing package — rather than
  as an obscure `UndefinedFunctionError` at test time.

      LemonPlatformTest.require_dep!("PluginCase", LemonChannels.Plugin, :lemon_channels)
  """
  @spec require_dep!(String.t(), module(), atom()) :: :ok
  def require_dep!(case_name, module, dep) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      raise """
      LemonPlatformTest.#{case_name} needs #{inspect(module)}, which is not loaded.

      The platform apps are optional dependencies of :lemon_platform_test, so you
      compile only the one your case uses. Add it to your test deps:

          {#{inspect(dep)}, "~> 0.1", only: :test}

      then `mix deps.get` and recompile.
      """
    end
  end
end
