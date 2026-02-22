defmodule Elixir.CodingAgent.Extensions.ExtensionTest do
  alias Elixir.CodingAgent, as: CodingAgent
  @moduledoc """
  Tests for the Extension behaviour module.
  
  This module tests that the Extension behaviour is correctly defined
  and can be implemented by modules.
  """
  
  use ExUnit.Case, async: true
  
  alias Elixir.CodingAgent.Extensions.Extension
  
  # Example extension that implements all callbacks
  defmodule FullExtension do
    @behaviour Extension
    
    @impl true
    def name, do: "full-extension"
    
    @impl true
    def version, do: "1.0.0"
    
    @impl true
    def tools(_cwd) do
      [
        %{
          name: "test_tool",
          description: "A test tool",
          parameters: %{}
        }
      ]
    end
    
    @impl true
    def hooks do
      [
        on_agent_start: fn -> :ok end,
        on_agent_end: fn _messages -> :ok end
      ]
    end
    
    @impl true
    def capabilities, do: [:tools, :hooks]
    
    @impl true
    def config_schema do
      %{
        "type" => "object",
        "properties" => %{
          "enabled" => %{"type" => "boolean", "default" => true}
        }
      }
    end
    
    @impl true
    def providers do
      [
        %{
          type: :model,
          name: :test_model,
          module: __MODULE__,
          config: %{}
        }
      ]
    end
  end
  
  # Minimal extension implementing only required callbacks
  defmodule Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension do
    @behaviour Extension
    
    @impl true
    def name, do: "minimal-extension"
    
    @impl true
    def version, do: "0.1.0"
  end
  
  # Partial extension implementing some optional callbacks
  defmodule PartialExtension do
    @behaviour Extension
    
    @impl true
    def name, do: "partial-extension"
    
    @impl true
    def version, do: "0.5.0"
    
    @impl true
    def tools(_cwd), do: []
    
    @impl true
    def capabilities, do: [:tools]
  end
  
  # ============================================================================
  # Required Callbacks Tests
  # ============================================================================
  
  describe "required callbacks" do
    test "name/0 returns extension name" do
      assert FullExtension.name() == "full-extension"
      assert Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension.name() == "minimal-extension"
    end
    
    test "version/0 returns version string" do
      assert FullExtension.version() == "1.0.0"
      assert Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension.version() == "0.1.0"
    end
    
    test "required callbacks are enforced by behaviour" do
      # The behaviour requires name/0 and version/0
      callbacks = Extension.behaviour_info(:callbacks)
      
      assert {:name, 0} in callbacks
      assert {:version, 0} in callbacks
    end
  end
  
  # ============================================================================
  # Optional Callbacks Tests
  # ============================================================================
  
  describe "optional callback: tools/1" do
    test "full extension returns list of tools" do
      tools = FullExtension.tools("/test/path")
      
      assert is_list(tools)
      assert length(tools) == 1
      assert hd(tools).name == "test_tool"
    end
    
    test "partial extension can implement tools/1" do
      assert PartialExtension.tools("/path") == []
    end
    
    test "minimal extension raises when tools/1 called" do
      assert_raise UndefinedFunctionError, fn ->
        apply(Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension, :tools, ["/path"])
      end
    end
  end
  
  describe "optional callback: hooks/0" do
    test "full extension returns keyword list" do
      hooks = FullExtension.hooks()
      
      assert is_list(hooks)
      assert Keyword.has_key?(hooks, :on_agent_start)
      assert Keyword.has_key?(hooks, :on_agent_end)
    end
    
    test "hooks are functions" do
      hooks = FullExtension.hooks()
      
      assert is_function(hooks[:on_agent_start], 0)
      assert is_function(hooks[:on_agent_end], 1)
    end
  end
  
  describe "optional callback: capabilities/0" do
    test "full extension returns list of atoms" do
      caps = FullExtension.capabilities()
      
      assert is_list(caps)
      assert :tools in caps
      assert :hooks in caps
    end
    
    test "partial extension returns capabilities" do
      assert PartialExtension.capabilities() == [:tools]
    end
  end
  
  describe "optional callback: config_schema/0" do
    test "full extension returns schema map" do
      schema = FullExtension.config_schema()
      
      assert is_map(schema)
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
    end
  end
  
  describe "optional callback: providers/0" do
    test "full extension returns list of provider specs" do
      providers = FullExtension.providers()
      
      assert is_list(providers)
      assert length(providers) == 1
      
      provider = hd(providers)
      assert provider.type == :model
      assert provider.name == :test_model
      assert is_atom(provider.module)
      assert is_map(provider.config)
    end
  end
  
  # ============================================================================
  # Provider Spec Type Tests
  # ============================================================================
  
  describe "provider_spec type" do
    test "provider spec has required fields" do
      provider = %{
        type: :model,
        name: :my_provider,
        module: __MODULE__,
        config: %{api_key: "secret"}
      }
      
      assert provider.type == :model
      assert provider.name == :my_provider
      assert provider.module == __MODULE__
      assert provider.config.api_key == "secret"
    end
    
    test "provider type can be different atoms" do
      model_provider = %{type: :model, name: :test, module: __MODULE__, config: %{}}
      tool_provider = %{type: :tool_executor, name: :test, module: __MODULE__, config: %{}}
      storage_provider = %{type: :storage, name: :test, module: __MODULE__, config: %{}}
      
      assert model_provider.type == :model
      assert tool_provider.type == :tool_executor
      assert storage_provider.type == :storage
    end
  end
  
  # ============================================================================
  # Behaviour Introspection Tests
  # ============================================================================
  
  describe "behaviour introspection" do
    test "can get all callbacks" do
      callbacks = Extension.behaviour_info(:callbacks)
      
      assert is_list(callbacks)
      assert {:name, 0} in callbacks
      assert {:version, 0} in callbacks
      assert {:tools, 1} in callbacks
      assert {:hooks, 0} in callbacks
      assert {:capabilities, 0} in callbacks
      assert {:config_schema, 0} in callbacks
      assert {:providers, 0} in callbacks
    end
    
    test "can get optional callbacks" do
      optional = Extension.behaviour_info(:optional_callbacks)
      
      assert is_list(optional)
      assert {:tools, 1} in optional
      assert {:hooks, 0} in optional
      assert {:capabilities, 0} in optional
      assert {:config_schema, 0} in optional
      assert {:providers, 0} in optional
      
      # Required callbacks should not be in optional
      refute {:name, 0} in optional
      refute {:version, 0} in optional
    end
  end
  
  # ============================================================================
  # Callback Arity Tests
  # ============================================================================
  
  describe "callback arity" do
    test "tools/1 takes cwd parameter" do
      # Should accept a string path
      tools = FullExtension.tools("/some/path")
      assert is_list(tools)
      
      # Should accept another path
      tools = FullExtension.tools("/different/path")
      assert is_list(tools)
    end
    
    test "name/0 and version/0 take no arguments" do
      assert function_exported?(FullExtension, :name, 0)
      assert function_exported?(FullExtension, :version, 0)
      
      refute function_exported?(FullExtension, :name, 1)
      refute function_exported?(FullExtension, :version, 1)
    end
  end
  
  # ============================================================================
  # Implementation Patterns Tests
  # ============================================================================
  
  describe "implementation patterns" do
    test "extension names follow kebab-case convention" do
      # Extensions should use lowercase with hyphens
      name = FullExtension.name()
      assert is_binary(name)
      assert Regex.match?(~r/^[a-z0-9-]+$/, name)
    end
    
    test "versions follow semantic versioning" do
      version = FullExtension.version()
      assert is_binary(version)
      # Basic semver pattern: major.minor.patch
      assert Regex.match?(~r/^\d+\.\d+\.\d+/, version)
    end
    
    test "capabilities are atoms" do
      for cap <- FullExtension.capabilities() do
        assert is_atom(cap)
      end
    end
  end
  
  # ============================================================================
  # Error Handling Tests
  # ============================================================================
  
  describe "error handling" do
    test "calling optional callback on minimal extension raises" do
      assert_raise UndefinedFunctionError, fn ->
        apply(Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension, :tools, ["/path"])
      end

      assert_raise UndefinedFunctionError, fn ->
        apply(Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension, :hooks, [])
      end

      assert_raise UndefinedFunctionError, fn ->
        apply(Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension, :capabilities, [])
      end
    end
    
    test "implementing only required callbacks is valid" do
      # Should be able to use minimal extension for basic operations
      assert Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension.name() == "minimal-extension"
      assert Elixir.CodingAgent.Extensions.ExtensionTest.MinimalExtension.version() == "0.1.0"
    end
  end
end
