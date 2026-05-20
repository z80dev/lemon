defmodule CodingAgent.Tools.XSearchTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.XSearch

  describe "module structure" do
    test "module is loadable" do
      assert {:module, XSearch} = Code.ensure_loaded(XSearch)
    end

    test "exports tool/2" do
      Code.ensure_loaded!(XSearch)
      assert function_exported?(XSearch, :tool, 2)
    end
  end
end
