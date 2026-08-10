defmodule LemonCore.EnvTest do
  @moduledoc """
  Tests for the LemonCore.Env typed environment-variable registry.

  This exercises real declared vars (e.g. LEMON_WASM_ENABLED,
  LEMON_WEB_PORT) that other config test files also read via
  `LemonCore.Config.*`, so -- like every other test file in
  test/lemon_core/config/ that touches those same vars -- this must run
  `async: false` to avoid racing on shared process env state.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Env

  setup do
    original_env = System.get_env()

    on_exit(fn ->
      System.get_env()
      |> Enum.each(fn {key, _} ->
        if Map.has_key?(original_env, key) do
          System.put_env(key, original_env[key])
        else
          System.delete_env(key)
        end
      end)
    end)

    :ok
  end

  defmodule TestRegistry do
    @moduledoc false
    use LemonCore.Env.Registry

    @declarations [
      %{
        name: :env_test_ratio,
        env_var: "ENV_TEST_RATIO",
        aliases: [],
        type: :float,
        default: 0.5,
        doc: "Float casting fixture.",
        secret?: false,
        required?: false,
        area: :env_test,
        apps: [:lemon_core]
      },
      %{
        name: :env_test_models,
        env_var: "ENV_TEST_MODELS",
        aliases: ["ENV_TEST_MODELS_LEGACY"],
        type: :list,
        default: [],
        doc: "Alias resolution fixture.",
        secret?: false,
        required?: false,
        area: :env_test,
        apps: [:lemon_core]
      }
    ]
  end

  defp with_test_registry(fun) do
    original = Application.get_env(:lemon_core, :env_registries)
    Application.put_env(:lemon_core, :env_registries, [TestRegistry])

    try do
      fun.()
    after
      if original do
        Application.put_env(:lemon_core, :env_registries, original)
      else
        Application.delete_env(:lemon_core, :env_registries)
      end
    end
  end

  describe "registries/0 aggregation" do
    test "defaults to lemon_core's own declarations" do
      original = Application.get_env(:lemon_core, :env_registries)
      Application.delete_env(:lemon_core, :env_registries)

      try do
        assert Env.registries() == [LemonCore.Env.Declarations]
        assert Enum.any?(Env.all_declared(), &(&1.name == :lemon_base_delay_ms))
      after
        if original, do: Application.put_env(:lemon_core, :env_registries, original)
      end
    end

    test "aggregates every listed registry" do
      with_test_registry(fn ->
        names = Enum.map(Env.all_declared(), & &1.name)
        assert :env_test_ratio in names
        assert :env_test_models in names
      end)
    end

    test "skips registries whose module is not loaded" do
      original = Application.get_env(:lemon_core, :env_registries)

      Application.put_env(:lemon_core, :env_registries, [
        LemonCore.Env.Declarations,
        :"Elixir.SomeApp.NotCompiled.Env"
      ])

      # Deleting instead of restoring would strip every app's registry for the
      # rest of the umbrella run — the apps that follow share this BEAM, and
      # their declared variables would start raising.
      on_exit(fn ->
        if original do
          Application.put_env(:lemon_core, :env_registries, original)
        else
          Application.delete_env(:lemon_core, :env_registries)
        end
      end)

      # An app missing from this build must not break the aggregate.
      assert Enum.any?(Env.all_declared(), &(&1.name == :lemon_base_delay_ms))
    end
  end

  describe "all_declared/0" do
    test "returns a non-empty list of declarations" do
      declared = Env.all_declared()
      assert is_list(declared)
      assert length(declared) > 50
    end

    test "every declaration has a unique name across the loaded registries" do
      names = Enum.map(Env.all_declared(), & &1.name)
      assert length(names) == length(Enum.uniq(names))
    end

    test "every declaration has a unique canonical env_var across the loaded registries" do
      env_vars = Enum.map(Env.all_declared(), & &1.env_var)
      assert length(env_vars) == length(Enum.uniq(env_vars))
    end

    # A name that is one declaration's canonical variable and another's alias is
    # a silent coupling: renaming the canonical one changes what the other falls
    # back to, and nothing above catches it because neither list has duplicates
    # on its own. The known-deliberate overlaps are listed so a *new* one fails.
    test "no declaration aliases another declaration's canonical env_var" do
      declared = Env.all_declared()
      canonical = MapSet.new(declared, & &1.env_var)

      intentional =
        MapSet.new([
          # lemon_evals deliberately falls back to the shared Anthropic key
          # rather than requiring a separate one for integration runs.
          "ANTHROPIC_API_KEY"
        ])

      overlaps =
        for decl <- declared,
            alias_var <- decl.aliases,
            MapSet.member?(canonical, alias_var),
            not MapSet.member?(intentional, alias_var),
            do: {decl.name, alias_var}

      assert overlaps == [],
             "these declarations alias another declaration's canonical env_var: " <>
               "#{inspect(overlaps)}. Either drop the alias or add it to `intentional` " <>
               "with a note explaining why the two variables are meant to be the same knob."
    end

    test "every declaration has the expected shape" do
      for decl <- Env.all_declared() do
        assert is_atom(decl.name)
        assert is_binary(decl.env_var)
        assert is_list(decl.aliases)
        assert decl.type in [:string, :integer, :float, :boolean, :list, :bytes]
        assert is_binary(decl.doc)
        assert is_boolean(decl.secret?)
        assert is_boolean(decl.required?)
        assert is_atom(decl.area)
        assert is_list(decl.apps)
      end
    end
  end

  describe "describe/1 and by_area/1" do
    test "describe/1 finds a declared variable by name" do
      decl = Env.describe(:lemon_base_delay_ms)
      assert decl.env_var == "LEMON_BASE_DELAY_MS"
      assert decl.type == :integer
      assert decl.default == 1000
    end

    test "describe/1 returns nil for an undeclared name" do
      assert Env.describe(:definitely_not_declared) == nil
    end

    test "by_area/1 returns only declarations in that area" do
      agent_decls = Env.by_area(:agent)
      assert agent_decls != []
      assert Enum.all?(agent_decls, &(&1.area == :agent))
    end
  end

  describe "get/2 resolution" do
    test "falls back to the declared default when unset" do
      System.delete_env("LEMON_BASE_DELAY_MS")
      assert Env.get(:lemon_base_delay_ms) == 1000
    end

    test "reads and casts the primary env_var when set" do
      System.put_env("LEMON_BASE_DELAY_MS", "9999")
      assert Env.get(:lemon_base_delay_ms) == 9999
    end

    test "falls back to a declared alias when the primary var is unset" do
      with_test_registry(fn ->
        System.delete_env("ENV_TEST_MODELS")
        System.put_env("ENV_TEST_MODELS_LEGACY", "anthropic:claude-sonnet-4-20250514")

        assert Env.get(:env_test_models) == ["anthropic:claude-sonnet-4-20250514"]
      end)
    end

    test "prefers the primary env_var over an alias when both are set" do
      with_test_registry(fn ->
        System.put_env("ENV_TEST_MODELS", "primary:model")
        System.put_env("ENV_TEST_MODELS_LEGACY", "legacy:model")

        assert Env.get(:env_test_models) == ["primary:model"]
      end)
    end

    test "opts[:default] overrides the declared default" do
      System.delete_env("LEMON_BASE_DELAY_MS")
      assert Env.get(:lemon_base_delay_ms, default: 1234) == 1234
    end

    test "casts booleans" do
      System.put_env("LEMON_WASM_ENABLED", "true")
      assert Env.get(:lemon_wasm_enabled) == true

      System.put_env("LEMON_WASM_ENABLED", "0")
      assert Env.get(:lemon_wasm_enabled) == false
    end

    test "casts floats" do
      with_test_registry(fn ->
        System.put_env("ENV_TEST_RATIO", "0.75")
        assert Env.get(:env_test_ratio) == 0.75
      end)
    end

    test "casts byte sizes" do
      System.put_env("LEMON_WASM_DEFAULT_MEMORY_LIMIT", "5MB")
      assert Env.get(:lemon_wasm_default_memory_limit) == 5_242_880
    end

    test "raises ArgumentError for an undeclared name" do
      assert_raise ArgumentError, ~r/no variable declared as :totally_made_up/, fn ->
        Env.get(:totally_made_up)
      end
    end
  end

  describe "get/2 required behavior" do
    test "raises when required and the resolved value is blank" do
      System.delete_env("LEMON_SHELL_PATH")

      assert_raise ArgumentError,
                   ~r/Missing required environment variable: LEMON_SHELL_PATH/,
                   fn ->
                     Env.get(:lemon_shell_path, required: true)
                   end
    end

    test "does not raise when required and a value is present" do
      System.put_env("LEMON_SHELL_PATH", "/bin/zsh")
      assert Env.get(:lemon_shell_path, required: true) == "/bin/zsh"
    end
  end

  describe "raw string/int/bool/list helpers" do
    test "string/1,2" do
      System.delete_env("LEMON_ENV_TEST_RAW_STRING")
      assert Env.string("LEMON_ENV_TEST_RAW_STRING") == nil
      assert Env.string("LEMON_ENV_TEST_RAW_STRING", "fallback") == "fallback"

      System.put_env("LEMON_ENV_TEST_RAW_STRING", "value")
      assert Env.string("LEMON_ENV_TEST_RAW_STRING") == "value"
    end

    test "int/1,2" do
      System.delete_env("LEMON_ENV_TEST_RAW_INT")
      assert Env.int("LEMON_ENV_TEST_RAW_INT", 42) == 42

      System.put_env("LEMON_ENV_TEST_RAW_INT", "7")
      assert Env.int("LEMON_ENV_TEST_RAW_INT", 42) == 7
    end

    test "bool/1,2" do
      System.delete_env("LEMON_ENV_TEST_RAW_BOOL")
      assert Env.bool("LEMON_ENV_TEST_RAW_BOOL", false) == false

      System.put_env("LEMON_ENV_TEST_RAW_BOOL", "yes")
      assert Env.bool("LEMON_ENV_TEST_RAW_BOOL", false) == true
    end

    test "list/1,2" do
      System.delete_env("LEMON_ENV_TEST_RAW_LIST")
      assert Env.list("LEMON_ENV_TEST_RAW_LIST") == []

      System.put_env("LEMON_ENV_TEST_RAW_LIST", "a,b,c")
      assert Env.list("LEMON_ENV_TEST_RAW_LIST") == ["a", "b", "c"]
    end
  end

  describe "snapshot/0 and secret redaction" do
    test "returns one Resolved entry per declaration" do
      snapshot = Env.snapshot()
      assert length(snapshot) == length(Env.all_declared())
      assert Enum.all?(snapshot, &match?(%LemonCore.Env.Resolved{}, &1))
    end

    test "tags resolution source as :default, :env, or :alias" do
      with_test_registry(fn ->
        System.delete_env("ENV_TEST_RATIO")
        System.delete_env("ENV_TEST_MODELS")
        System.put_env("ENV_TEST_MODELS_LEGACY", "legacy:model")

        snapshot = Env.snapshot()

        ratio_entry = Enum.find(snapshot, &(&1.name == :env_test_ratio))
        assert ratio_entry.source == :default
        assert ratio_entry.value == 0.5

        models_entry = Enum.find(snapshot, &(&1.name == :env_test_models))
        assert models_entry.source == :alias
        assert models_entry.value == ["legacy:model"]
      end)
    end

    test "redacts secret values when inspected, but leaves the raw value readable" do
      System.put_env("SENTRY_DSN", "https://public:secret@example.com/1")

      snapshot = Env.snapshot()
      sentry_entry = Enum.find(snapshot, &(&1.name == :sentry_dsn))

      assert sentry_entry.secret? == true
      assert sentry_entry.value == "https://public:secret@example.com/1"
      refute inspect(sentry_entry) =~ "secret@example.com"
      assert inspect(sentry_entry) =~ "REDACTED"
    end

    test "does not redact non-secret values when inspected" do
      System.put_env("LEMON_BASE_DELAY_MS", "4080")

      snapshot = Env.snapshot()
      delay_entry = Enum.find(snapshot, &(&1.name == :lemon_base_delay_ms))

      assert inspect(delay_entry) =~ "4080"
    end

    test "renders nil secret values as nil, not redacted" do
      System.delete_env("SENTRY_DSN")

      snapshot = Env.snapshot()
      sentry_entry = Enum.find(snapshot, &(&1.name == :sentry_dsn))

      assert inspect(sentry_entry) =~ "= nil,"
    end
  end
end
