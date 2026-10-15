defmodule LemonCore.Config.Tools.BashTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.{Tools, Validator}

  test "bash interceptor defaults are disabled and valid" do
    config = Tools.resolve(%{})
    refute config.bash.interceptor.enabled
    assert length(config.bash.interceptor.rules) == 6
    assert Validator.validate_tools(config, []) == []
    assert Tools.defaults()["bash"]["interceptor"]["enabled"] == false
  end

  test "invalid tables, booleans, lists and regex rules fail validation" do
    for bash <- [
          false,
          %{"interceptor" => false},
          %{"interceptor" => %{"enabled" => "yes"}},
          %{"interceptor" => %{"rules" => false}},
          %{
            "interceptor" => %{
              "rules" => [%{"pattern" => "[", "tool" => "read", "message" => "bad"}]
            }
          },
          %{
            "interceptor" => %{"rules" => [%{"pattern" => "x", "tool" => "", "message" => "bad"}]}
          }
        ] do
      config = Tools.resolve(%{"tools" => %{"bash" => bash}})

      assert Enum.any?(
               Validator.validate_tools(config, []),
               &String.contains?(&1, "runtime.tools.bash")
             )
    end
  end
end
