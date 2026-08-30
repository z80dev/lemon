defmodule CodingAgent.Tools.BrowserExecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{ToolPolicy, Tools}
  alias LemonAgent.Types.AgentToolResult

  test "runs a bounded BUA-style program and carries the active target forward" do
    parent = self()

    request = fn method, args, timeout ->
      send(parent, {:request, method, args, timeout})

      case method do
        "browser.tabOpen" -> {:ok, %{"targetId" => "tab-9", "active" => true}}
        "browser.snapshot" -> {:ok, %{"text" => "button Continue"}}
        "browser.click" -> {:ok, %{"clicked" => true}}
      end
    end

    tool = Tools.get_tool("browser_exec", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{
          "steps" => [
            %{
              "action" => "tab_open",
              "args" => %{"url" => "https://example.com"},
              "timeoutMs" => 500
            },
            %{"action" => "snapshot", "args" => %{"targetId" => "$active"}},
            %{
              "action" => "click",
              "args" => %{"targetId" => "$active", "selector" => "text=Continue"}
            }
          ]
        },
        nil,
        nil
      )

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted
    assert result.details["ok"]
    assert result.details["completedSteps"] == 3

    assert Enum.map(result.details["results"], & &1["action"]) ==
             ~w(tab_open snapshot click)

    assert_received {:request, "browser.tabOpen", %{"url" => "https://example.com"}, 500}
    assert_received {:request, "browser.snapshot", %{"targetId" => "tab-9"}, 30_000}

    assert_received {:request, "browser.click",
                     %{"targetId" => "tab-9", "selector" => "text=Continue"}, 30_000}
  end

  test "stops on the first failed step and preserves completed evidence" do
    request = fn
      "browser.tabs", _args, _timeout -> {:ok, %{"tabs" => []}}
      "browser.click", _args, _timeout -> {:error, :stale_target}
      _method, _args, _timeout -> flunk("steps after failure must not execute")
    end

    tool = Tools.get_tool("browser_exec", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{
          "steps" => [
            %{"action" => "tabs", "args" => %{}},
            %{"action" => "click", "args" => %{"selector" => "button"}},
            %{"action" => "snapshot", "args" => %{}}
          ]
        },
        nil,
        nil
      )

    refute result.details["ok"]
    assert result.details["completedSteps"] == 1
    assert result.details["failedStep"] == 1
    assert result.details["failedAction"] == "click"
    assert length(result.details["results"]) == 1
  end

  test "navigation route guards apply before a provider sees the step" do
    request = fn _method, _args, _timeout -> flunk("blocked navigation reached provider") end
    tool = Tools.get_tool("browser_exec", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{
          "steps" => [
            %{
              "action" => "navigate",
              "args" => %{"url" => "http://169.254.169.254/latest/meta-data"}
            }
          ]
        },
        nil,
        nil
      )

    refute result.details["ok"]
    assert result.details["failedStep"] == 0
    assert result.details["error"] =~ "metadata"
  end

  test "raw CDP is developer gated and forwards only after opt in" do
    step = %{
      "steps" => [
        %{
          "action" => "cdp",
          "args" => %{"method" => "Runtime.evaluate", "params" => %{"expression" => "6 * 7"}}
        }
      ]
    }

    request = fn method, args, timeout ->
      send(self(), {:cdp, method, args, timeout})
      {:ok, %{"result" => %{"value" => 42}}}
    end

    blocked = Tools.get_tool("browser_exec", "/tmp", browser_request: request)
    assert {:error, reason} = blocked.execute.("call", step, nil, nil)
    assert reason =~ "developer"

    enabled =
      Tools.get_tool("browser_exec", "/tmp",
        browser_request: request,
        browser_developer_mode: true
      )

    result = enabled.execute.("call", step, nil, nil)
    assert result.details["ok"]
    assert result.details["results"] |> hd() |> get_in(["output", "result", "value"]) == 42
  end

  test "is denied by safe and no-external policy profiles" do
    refute ToolPolicy.allowed?(ToolPolicy.from_profile(:safe_mode), "browser_exec")
    refute ToolPolicy.allowed?(ToolPolicy.from_profile(:no_external), "browser_exec")
  end
end
