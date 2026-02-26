defmodule LemonControlPlane.Methods.SendTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.Send

  describe "Send.handle/2" do
    test "name returns correct method name" do
      assert Send.name() == "send"
    end

    test "scopes returns write scope" do
      assert Send.scopes() == [:write]
    end

    test "returns error when channelId is missing" do
      ctx = %{auth: %{role: :operator}}
      params = %{"content" => "Hello"}

      {:error, error} = Send.handle(params, ctx)

      assert error == {:invalid_request, "channelId is required", nil}
    end

    test "returns error when content is missing" do
      ctx = %{auth: %{role: :operator}}
      params = %{"channelId" => "telegram"}

      {:error, error} = Send.handle(params, ctx)

      assert error == {:invalid_request, "content is required", nil}
    end
  end
end
