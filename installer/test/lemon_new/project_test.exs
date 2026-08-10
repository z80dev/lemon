defmodule LemonNew.ProjectTest do
  use ExUnit.Case, async: true

  alias LemonNew.Project

  defp new(path, opts \\ []), do: Project.new(path, Keyword.put(opts, :lemon_path, "/opt/lemon"))

  test "derives app and module from the path" do
    project = new("tmp/support_bot")

    assert project.app == "support_bot"
    assert project.app_module == "SupportBot"
    assert project.base_path == Path.expand("tmp/support_bot")
  end

  test "explicit app and module win" do
    project = new("tmp/whatever", app: "support_bot", module: "Support.Bot")

    assert project.app == "support_bot"
    assert project.app_module == "Support.Bot"
  end

  test "rejects application names Mix cannot use" do
    for bad <- ~w(My-Agent 1agent MyAgent my.agent) do
      assert_raise ArgumentError, ~r/application name must start/, fn ->
        Project.validate_app!(bad)
      end
    end
  end

  test "rejects application names that collide with OTP applications" do
    assert_raise ArgumentError, ~r/collides/, fn -> Project.validate_app!("logger") end
  end

  test "accepts ordinary application names" do
    for good <- ~w(my_agent agent a agent2) do
      assert Project.validate_app!(good) == :ok
    end
  end

  test "rejects module names that are not aliases" do
    for bad <- ["my_agent", "myAgent", "My.agent", "My Agent"] do
      assert_raise ArgumentError, ~r/valid Elixir alias/, fn ->
        Project.validate_module!(bad)
      end
    end
  end

  test "accepts nested module names" do
    assert Project.validate_module!("Support.Bot") == :ok
  end
end
