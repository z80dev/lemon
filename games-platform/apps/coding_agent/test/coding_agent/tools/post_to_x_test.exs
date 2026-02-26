defmodule CodingAgent.Tools.PostToXTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.PostToX

  describe "module structure" do
    test "module is loadable" do
      assert {:module, PostToX} = Code.ensure_loaded(PostToX)
    end

    test "exports tool/2" do
      Code.ensure_loaded!(PostToX)
      assert function_exported?(PostToX, :tool, 2)
    end
  end
end
