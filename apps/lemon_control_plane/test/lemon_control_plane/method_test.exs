defmodule LemonControlPlane.MethodTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Method

  # -------------------------------------------------------------------
  # Test module using the macro
  # -------------------------------------------------------------------

  defmodule SampleMethod do
    use LemonControlPlane.Method,
      name: "test.sample",
      scopes: [:read, :write],
      schema: %{
        required: %{"foo" => :string},
        optional: %{"bar" => :integer}
      },
      capabilities: [:sample_cap]

    @impl true
    def handle(params, _ctx), do: {:ok, params}
  end

  defmodule MinimalMethod do
    use LemonControlPlane.Method,
      name: "test.minimal"

    @impl true
    def handle(_params, _ctx), do: {:ok, %{"minimal" => true}}
  end

  # A module that manually implements the behaviour (no macro)
  defmodule LegacyMethod do
    @behaviour LemonControlPlane.Method

    @impl true
    def name, do: "test.legacy"

    @impl true
    def scopes, do: [:admin]

    @impl true
    def handle(_params, _ctx), do: {:ok, %{"legacy" => true}}
  end

  # -------------------------------------------------------------------
  # Tests for macro-generated functions
  # -------------------------------------------------------------------

  describe "use LemonControlPlane.Method macro" do
    test "generates name/0 from opts" do
      assert SampleMethod.name() == "test.sample"
    end

    test "generates scopes/0 from opts" do
      assert SampleMethod.scopes() == [:read, :write]
    end

    test "generates __schema__/0 from opts" do
      schema = SampleMethod.__schema__()
      assert schema == %{required: %{"foo" => :string}, optional: %{"bar" => :integer}}
    end

    test "generates __capabilities__/0 from opts" do
      assert SampleMethod.__capabilities__() == [:sample_cap]
    end

    test "handle/2 still works as a callback" do
      assert {:ok, %{"x" => 1}} = SampleMethod.handle(%{"x" => 1}, %{})
    end
  end

  describe "minimal macro usage (defaults)" do
    test "scopes defaults to []" do
      assert MinimalMethod.scopes() == []
    end

    test "schema defaults to %{}" do
      assert MinimalMethod.__schema__() == %{}
    end

    test "capabilities defaults to []" do
      assert MinimalMethod.__capabilities__() == []
    end

    test "name is set correctly" do
      assert MinimalMethod.name() == "test.minimal"
    end
  end

  describe "legacy (non-macro) method modules" do
    test "still implement the behaviour correctly" do
      assert LegacyMethod.name() == "test.legacy"
      assert LegacyMethod.scopes() == [:admin]
      assert {:ok, %{"legacy" => true}} = LegacyMethod.handle(%{}, %{})
    end

    test "do NOT export __schema__/0" do
      refute function_exported?(LegacyMethod, :__schema__, 0)
    end

    test "do NOT export __capabilities__/0" do
      refute function_exported?(LegacyMethod, :__capabilities__, 0)
    end
  end

  describe "has_macro_metadata?/1" do
    test "returns true for macro-based modules" do
      assert Method.has_macro_metadata?(SampleMethod)
      assert Method.has_macro_metadata?(MinimalMethod)
    end

    test "returns false for legacy modules" do
      refute Method.has_macro_metadata?(LegacyMethod)
    end

    test "returns false for unrelated modules" do
      refute Method.has_macro_metadata?(String)
    end
  end

  describe "require_param/2" do
    test "returns {:ok, value} when param is present" do
      assert {:ok, "hello"} = Method.require_param(%{"key" => "hello"}, "key")
    end

    test "returns error tuple when param is nil" do
      assert {:error, {:invalid_request, "key is required", nil}} =
               Method.require_param(%{}, "key")
    end

    test "returns error tuple when param value is nil" do
      assert {:error, {:invalid_request, "key is required", nil}} =
               Method.require_param(%{"key" => nil}, "key")
    end
  end

  describe "discover_methods/0" do
    test "discovers macro-based method modules under LemonControlPlane.Methods.*" do
      # Ensure our real migrated modules are loaded
      _ = Code.ensure_loaded(LemonControlPlane.Methods.Health)
      _ = Code.ensure_loaded(LemonControlPlane.Methods.Status)
      _ = Code.ensure_loaded(LemonControlPlane.Methods.ChannelsStatus)
      _ = Code.ensure_loaded(LemonControlPlane.Methods.LogsTail)
      _ = Code.ensure_loaded(LemonControlPlane.Methods.UsageStatus)

      discovered = Method.discover_methods()
      names = Enum.map(discovered, fn {name, _mod} -> name end)

      assert "health" in names
      assert "status" in names
      assert "channels.status" in names
      assert "logs.tail" in names
      assert "usage.status" in names
    end

    test "does NOT discover legacy (non-macro) modules" do
      # ChatSend is not migrated, so it should not appear
      _ = Code.ensure_loaded(LemonControlPlane.Methods.ChatSend)

      discovered = Method.discover_methods()
      names = Enum.map(discovered, fn {name, _mod} -> name end)

      refute "chat.send" in names
    end

    test "does NOT discover test helper modules outside Methods namespace" do
      # Our test module SampleMethod is under MethodTest, not Methods
      discovered = Method.discover_methods()
      names = Enum.map(discovered, fn {name, _mod} -> name end)

      refute "test.sample" in names
    end
  end
end
