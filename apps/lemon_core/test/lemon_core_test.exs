defmodule LemonCoreTest do
  @moduledoc """
  Tests for the main LemonCore module.
  """
  use ExUnit.Case, async: true

  describe "module definition" do
    test "module exists and can be loaded" do
      assert Code.ensure_loaded?(LemonCore)
    end

    test "has proper moduledoc documentation" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(LemonCore)
      assert doc =~ "LemonCore provides shared primitives for the Lemon umbrella"
    end
  end

  describe "referenced sub-modules" do
    test "LemonCore.Event module exists" do
      assert Code.ensure_loaded?(LemonCore.Event)
    end

    test "LemonCore.Bus module exists" do
      assert Code.ensure_loaded?(LemonCore.Bus)
    end

    test "LemonCore.Id module exists" do
      assert Code.ensure_loaded?(LemonCore.Id)
    end

    test "LemonCore.Idempotency module exists" do
      assert Code.ensure_loaded?(LemonCore.Idempotency)
    end

    test "LemonCore.Store module exists" do
      assert Code.ensure_loaded?(LemonCore.Store)
    end

    test "LemonCore.Introspection module exists" do
      assert Code.ensure_loaded?(LemonCore.Introspection)
    end

    test "LemonCore.Telemetry module exists" do
      assert Code.ensure_loaded?(LemonCore.Telemetry)
    end

    test "LemonCore.Clock module exists" do
      assert Code.ensure_loaded?(LemonCore.Clock)
    end

    test "LemonCore.Config module exists" do
      assert Code.ensure_loaded?(LemonCore.Config)
    end
  end

  describe "module exports" do
    test "module has no public functions (documentation-only)" do
      # LemonCore is a documentation-only module
      public_functions = LemonCore.__info__(:functions)
      assert public_functions == []
    end
  end

  describe "OTP application" do
    test "lemon_core is a loaded application" do
      # Check the application is configured
      assert Application.get_application(LemonCore) == :lemon_core
    end

    test "application has registered modules" do
      # Verify that the modules are actually from this app
      {:ok, modules} = :application.get_key(:lemon_core, :modules)
      assert LemonCore in modules
      assert LemonCore.Event in modules
      assert LemonCore.Store in modules
    end
  end
end
