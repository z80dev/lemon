defmodule LemonCore.Config.Tools.BashTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.{Tools, Validator}

  test "bash interceptor defaults are disabled and valid" do
    config = Tools.resolve(%{})
    refute config.bash.interceptor.enabled
    assert length(config.bash.interceptor.rules) == 6
    assert Validator.validate_tools(config, []) == []
    assert Tools.defaults()["bash"]["interceptor"]["enabled"] == false
    assert config.bash.git_guard
    assert Tools.defaults()["bash"]["git_guard"]
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

  test "git guard accepts booleans only" do
    config = Tools.resolve(%{"tools" => %{"bash" => %{"git_guard" => false}}})
    refute config.bash.git_guard
    assert Validator.validate_tools(config, []) == []
    invalid = Tools.resolve(%{"tools" => %{"bash" => %{"git_guard" => "false"}}})

    assert "runtime.tools.bash.git_guard: must be a boolean" in Validator.validate_tools(
             invalid,
             []
           )
  end
end
