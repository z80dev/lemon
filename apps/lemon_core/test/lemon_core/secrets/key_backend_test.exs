defmodule LemonCore.Secrets.KeyBackendTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.{KeyBackend, KeyFile, Keychain, SecretService}

  @backends [Keychain, SecretService, KeyFile]

  describe "behaviour conformance" do
    for mod <- @backends do
      test "#{inspect(mod)} declares @behaviour KeyBackend" do
        mod = unquote(mod)
        assert Code.ensure_loaded?(mod)

        behaviours =
          mod.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert KeyBackend in behaviours,
               "#{inspect(mod)} does not declare @behaviour KeyBackend"
      end

      test "#{inspect(mod)} exports available?/0" do
        mod = unquote(mod)
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :available?, 0)
      end

      test "#{inspect(mod)} exports get_master_key/1" do
        mod = unquote(mod)
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :get_master_key, 1)
      end

      test "#{inspect(mod)} exports put_master_key/2" do
        mod = unquote(mod)
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :put_master_key, 2)
      end

      test "#{inspect(mod)} exports delete_master_key/1" do
        mod = unquote(mod)
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :delete_master_key, 1)
      end
    end
  end
end
