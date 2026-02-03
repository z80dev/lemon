defmodule LemonGateway.EngineRegistryTest do
  use ExUnit.Case, async: false

  alias LemonGateway.EngineRegistry
  alias LemonGateway.Types.ResumeToken

  # Mock engine that matches "alpha resume XXX"
  defmodule AlphaEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "alpha"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "alpha resume #{sid}"

    @impl true
    def extract_resume(text) do
      case Regex.run(~r/alpha\s+resume\s+([\w-]+)/i, text) do
        [_, value] -> %ResumeToken{engine: id(), value: value}
        _ -> nil
      end
    end

    @impl true
    def is_resume_line(line), do: Regex.match?(~r/^\s*`?alpha\s+resume\s+[\w-]+`?\s*$/i, line)

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine that matches "beta resume XXX"
  defmodule BetaEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "beta"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "beta resume #{sid}"

    @impl true
    def extract_resume(text) do
      case Regex.run(~r/beta\s+resume\s+([\w-]+)/i, text) do
        [_, value] -> %ResumeToken{engine: id(), value: value}
        _ -> nil
      end
    end

    @impl true
    def is_resume_line(line), do: Regex.match?(~r/^\s*`?beta\s+resume\s+[\w-]+`?\s*$/i, line)

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine that matches same pattern as AlphaEngine (for testing order)
  defmodule GammaEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "gamma"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "gamma resume #{sid}"

    # This also matches "alpha resume" - to test order matters
    @impl true
    def extract_resume(text) do
      case Regex.run(~r/alpha\s+resume\s+([\w-]+)/i, text) do
        [_, value] -> %ResumeToken{engine: id(), value: value}
        _ -> nil
      end
    end

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine with reserved ID "default"
  defmodule DefaultEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "default"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "default resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine with reserved ID "help"
  defmodule HelpEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "help"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "help resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine with invalid ID (uppercase)
  defmodule UppercaseIdEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "InvalidID"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "invalid resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine with invalid ID (starts with number)
  defmodule NumberStartIdEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "123engine"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "123 resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine with invalid ID (special characters)
  defmodule SpecialCharIdEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "engine@special"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "special resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Mock engine that never matches extract_resume
  defmodule NoMatchEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "nomatch"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "nomatch resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  # Duplicate engine module for testing duplicate ID handling
  # (same ID as AlphaEngine)
  defmodule DuplicateAlphaEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "alpha"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "alpha-dup resume #{sid}"

    @impl true
    def extract_resume(text) do
      case Regex.run(~r/alpha-dup\s+resume\s+([\w-]+)/i, text) do
        [_, value] -> %ResumeToken{engine: id(), value: value}
        _ -> nil
      end
    end

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}

    @impl true
    def cancel(_ctx), do: :ok
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false
    })

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, :engines)
    end)

    :ok
  end

  describe "extract_resume/1 with multiple engines" do
    test "returns token from first matching engine in order" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, BetaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Alpha matches first
      assert {:ok, %ResumeToken{engine: "alpha", value: "session123"}} =
               EngineRegistry.extract_resume("alpha resume session123")

      # Beta matches when alpha doesn't
      assert {:ok, %ResumeToken{engine: "beta", value: "session456"}} =
               EngineRegistry.extract_resume("beta resume session456")
    end

    test "order matters when multiple engines match same text" do
      # GammaEngine also matches "alpha resume" but should not win if Alpha is first
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, GammaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Alpha should match first since it's first in the list
      assert {:ok, %ResumeToken{engine: "alpha", value: "shared-id"}} =
               EngineRegistry.extract_resume("alpha resume shared-id")
    end

    test "second engine matches when first engine is listed second" do
      # Reverse order - Gamma is first, so it should match first
      Application.put_env(:lemon_gateway, :engines, [GammaEngine, AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Gamma should match first now since it's first in the list
      assert {:ok, %ResumeToken{engine: "gamma", value: "shared-id"}} =
               EngineRegistry.extract_resume("alpha resume shared-id")
    end

    test "returns :none when no engine matches" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, BetaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert :none = EngineRegistry.extract_resume("unrecognized pattern here")
    end

    test "returns :none when all engines return nil" do
      Application.put_env(:lemon_gateway, :engines, [NoMatchEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert :none = EngineRegistry.extract_resume("any text at all")
    end

    test "handles mixed matching and non-matching engines" do
      Application.put_env(:lemon_gateway, :engines, [NoMatchEngine, AlphaEngine, BetaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # NoMatch returns nil, so Alpha should match
      assert {:ok, %ResumeToken{engine: "alpha", value: "test123"}} =
               EngineRegistry.extract_resume("alpha resume test123")
    end
  end

  describe "reserved ID validation" do
    test "rejects engine with reserved ID 'default'" do
      Application.put_env(:lemon_gateway, :engines, [DefaultEngine])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects engine with reserved ID 'help'" do
      Application.put_env(:lemon_gateway, :engines, [HelpEngine])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "allows valid engine alongside check for reserved" do
      # Ensure valid engines still work
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.get_engine("alpha") == AlphaEngine
    end
  end

  describe "invalid ID format validation" do
    test "rejects engine ID with uppercase letters" do
      Application.put_env(:lemon_gateway, :engines, [UppercaseIdEngine])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects engine ID starting with number" do
      Application.put_env(:lemon_gateway, :engines, [NumberStartIdEngine])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects engine ID with special characters" do
      Application.put_env(:lemon_gateway, :engines, [SpecialCharIdEngine])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "accepts valid ID patterns" do
      # Valid patterns: lowercase letters, numbers after first char, hyphen, underscore
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, BetaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.get_engine("alpha") == AlphaEngine
      assert EngineRegistry.get_engine("beta") == BetaEngine
    end
  end

  describe "engine order preservation (state.order)" do
    test "list_engines returns IDs in registration order" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, BetaEngine, NoMatchEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.list_engines() == ["alpha", "beta", "nomatch"]
    end

    test "list_engines preserves reverse order" do
      Application.put_env(:lemon_gateway, :engines, [NoMatchEngine, BetaEngine, AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.list_engines() == ["nomatch", "beta", "alpha"]
    end

    test "order preserved with single engine" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.list_engines() == ["alpha"]
    end
  end

  describe "get_engine! error propagation" do
    test "raises ArgumentError for unknown engine ID" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert_raise ArgumentError, fn ->
        EngineRegistry.get_engine!("nonexistent")
      end
    end

    test "get_engine returns nil for unknown engine ID" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.get_engine("nonexistent") == nil
    end

    test "get_engine! succeeds for valid engine ID" do
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, BetaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.get_engine!("alpha") == AlphaEngine
      assert EngineRegistry.get_engine!("beta") == BetaEngine
    end
  end

  describe "empty engine list handling" do
    test "handles empty engine list gracefully" do
      Application.put_env(:lemon_gateway, :engines, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.list_engines() == []
    end

    test "extract_resume returns :none with empty engine list" do
      Application.put_env(:lemon_gateway, :engines, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert :none = EngineRegistry.extract_resume("any text")
    end

    test "get_engine returns nil for any ID with empty engine list" do
      Application.put_env(:lemon_gateway, :engines, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert EngineRegistry.get_engine("anything") == nil
    end

    test "get_engine! raises for any ID with empty engine list" do
      Application.put_env(:lemon_gateway, :engines, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert_raise ArgumentError, fn ->
        EngineRegistry.get_engine!("anything")
      end
    end
  end

  describe "duplicate engine ID handling" do
    # Note: The current implementation uses Map.put which silently overwrites
    # duplicates. These tests document the actual behavior.

    test "later duplicate engine overwrites earlier one in map" do
      # Both return "alpha" as ID, so later one wins in the map
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, DuplicateAlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # The map will have the later module
      assert EngineRegistry.get_engine("alpha") == DuplicateAlphaEngine
    end

    test "list_engines shows only unique IDs from order" do
      # The order list preserves both modules, but they have same ID
      Application.put_env(:lemon_gateway, :engines, [AlphaEngine, DuplicateAlphaEngine])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # list_engines maps over order calling id(), so we see "alpha" twice
      assert EngineRegistry.list_engines() == ["alpha", "alpha"]
    end
  end
end
