defmodule CodingAgent.Tools.GetXMentionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.GetXMentions

  describe "module structure" do
    test "module is loadable" do
      assert {:module, GetXMentions} = Code.ensure_loaded(GetXMentions)
    end

    test "exports tool/2" do
      Code.ensure_loaded!(GetXMentions)
      assert function_exported?(GetXMentions, :tool, 2)
    end
  end
end
