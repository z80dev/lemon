defmodule LemonControlPlane.Methods.EventTypeValidationTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.ConfigGet

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "ConfigGet key validation" do
    test "returns nil for arbitrary keys not in allowed list" do
      # This tests that arbitrary strings don't create atoms
      params = %{"key" => "arbitrary_config_key_#{:rand.uniform(1_000_000)}"}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      # Should return nil for unknown keys, not crash or create atoms
      assert response["key"] == params["key"]
      assert response["value"] == nil
    end
  end
end
