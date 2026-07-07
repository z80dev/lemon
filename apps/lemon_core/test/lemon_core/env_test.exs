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

  describe "all_declared/0" do
    test "returns a non-empty list of declarations" do
      declared = Env.all_declared()
      assert is_list(declared)
      assert length(declared) > 100
    end

    test "every declaration has a unique name" do
      names = Enum.map(Env.all_declared(), & &1.name)
      assert length(names) == length(Enum.uniq(names))
    end

    test "every declaration has a unique canonical env_var" do
      env_vars = Enum.map(Env.all_declared(), & &1.env_var)
      assert length(env_vars) == length(Enum.uniq(env_vars))
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
      decl = Env.describe(:lemon_web_port)
      assert decl.env_var == "LEMON_WEB_PORT"
      assert decl.type == :integer
      assert decl.default == 4080
    end

    test "describe/1 returns nil for an undeclared name" do
      assert Env.describe(:definitely_not_declared) == nil
    end

    test "by_area/1 returns only declarations in that area" do
      arena_decls = Env.by_area(:arena)
      assert arena_decls != []
      assert Enum.all?(arena_decls, &(&1.area == :arena))
    end
  end

  describe "get/2 resolution" do
    test "falls back to the declared default when unset" do
      System.delete_env("LEMON_WEB_PORT")
      assert Env.get(:lemon_web_port) == 4080
    end

    test "reads and casts the primary env_var when set" do
      System.put_env("LEMON_WEB_PORT", "9999")
      assert Env.get(:lemon_web_port) == 9999
    end

    test "falls back to a declared alias when the primary var is unset" do
      System.delete_env("LEMON_ARENA_WEREWOLF_MODELS")
      System.put_env("WEREWOLF_ARENA_MODELS", "anthropic:claude-sonnet-4-20250514")

      assert Env.get(:lemon_arena_werewolf_models) == ["anthropic:claude-sonnet-4-20250514"]
    end

    test "prefers the primary env_var over an alias when both are set" do
      System.put_env("LEMON_ARENA_WEREWOLF_MODELS", "primary:model")
      System.put_env("WEREWOLF_ARENA_MODELS", "legacy:model")

      assert Env.get(:lemon_arena_werewolf_models) == ["primary:model"]
    end

    test "opts[:default] overrides the declared default" do
      System.delete_env("LEMON_WEB_PORT")
      assert Env.get(:lemon_web_port, default: 1234) == 1234
    end

    test "casts booleans" do
      System.put_env("LEMON_WASM_ENABLED", "true")
      assert Env.get(:lemon_wasm_enabled) == true

      System.put_env("LEMON_WASM_ENABLED", "0")
      assert Env.get(:lemon_wasm_enabled) == false
    end

    test "casts floats" do
      System.put_env("LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO", "0.75")
      assert Env.get(:lemon_telegram_compaction_trigger_ratio) == 0.75
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
      System.delete_env("LEMON_WEB_PORT")
      System.delete_env("LEMON_ARENA_WEREWOLF_MODELS")
      System.put_env("WEREWOLF_ARENA_MODELS", "legacy:model")

      snapshot = Env.snapshot()

      port_entry = Enum.find(snapshot, &(&1.name == :lemon_web_port))
      assert port_entry.source == :default
      assert port_entry.value == 4080

      werewolf_entry = Enum.find(snapshot, &(&1.name == :lemon_arena_werewolf_models))
      assert werewolf_entry.source == :alias
      assert werewolf_entry.value == ["legacy:model"]
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
      System.put_env("LEMON_WEB_PORT", "4080")

      snapshot = Env.snapshot()
      port_entry = Enum.find(snapshot, &(&1.name == :lemon_web_port))

      assert inspect(port_entry) =~ "4080"
    end

    test "renders nil secret values as nil, not redacted" do
      System.delete_env("SENTRY_DSN")

      snapshot = Env.snapshot()
      sentry_entry = Enum.find(snapshot, &(&1.name == :sentry_dsn))

      assert inspect(sentry_entry) =~ "= nil,"
    end
  end
end
