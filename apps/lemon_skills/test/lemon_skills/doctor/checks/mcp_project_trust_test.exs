defmodule LemonSkills.Doctor.Checks.McpProjectTrustTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check
  alias LemonSkills.Doctor.Checks.McpProjectTrust
  alias LemonSkills.{McpConfig, McpDiscovery}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    saved_app = Application.fetch_env(:lemon_skills, :mcp_external_discovery)

    saved_env =
      Map.new(["LEMON_AGENT_DIR", "LEMON_MCP_EXTERNAL_DISCOVERY"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      case saved_app do
        {:ok, value} -> Application.put_env(:lemon_skills, :mcp_external_discovery, value)
        :error -> Application.delete_env(:lemon_skills, :mcp_external_discovery)
      end

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    System.delete_env("LEMON_MCP_EXTERNAL_DISCOVERY")
    Application.put_env(:lemon_skills, :mcp_external_discovery, true)
    project = Path.join(root, "project")
    File.mkdir_p!(project)
    %{project: project}
  end

  test "skips without project files or when discovery is off", %{project: project} do
    assert [%Check{name: "mcp.project_trust", status: :skip}] =
             McpProjectTrust.run(project_dir: project)

    write(project, ".mcp.json", %{"mcpServers" => %{"s" => %{"command" => "srv"}}})
    Application.put_env(:lemon_skills, :mcp_external_discovery, false)

    assert [%Check{name: "mcp.project_trust", status: :skip}] =
             McpProjectTrust.run(project_dir: project)
  end

  test "warns about pending and changed trust and rejected host values", %{project: project} do
    write(project, ".mcp.json", %{
      "mcpServers" => %{
        "s" => %{"command" => "srv"},
        "leak" => %{"command" => "srv", "args" => ["${HOME}"]}
      }
    })

    assert [pending, host_values] = McpProjectTrust.run(project_dir: project)
    assert %Check{name: "mcp.project_trust", status: :warn} = pending
    assert pending.message =~ ".mcp.json"
    assert pending.message =~ "1 server(s) will not start"
    assert pending.remediation =~ "lemon mcp trust --cwd '#{project}'"
    assert %Check{name: "mcp.project_host_values", status: :warn} = host_values
    assert host_values.message =~ "leak"
    refute host_values.message =~ System.user_home!()

    assert :ok = McpConfig.trust_project(project, McpDiscovery.project_status(project).digest)

    assert [%Check{status: :pass}, %Check{status: :warn}] =
             McpProjectTrust.run(project_dir: project)

    write(project, ".mcp.json", %{"mcpServers" => %{"s" => %{"command" => "other"}}})

    assert [%Check{status: :warn} = changed] = McpProjectTrust.run(project_dir: project)
    assert changed.message =~ "changed since they were trusted"
  end

  test "remediation quotes the project path or omits it when it cannot be shown safely", %{
    project: project
  } do
    quoted = Path.join(project, "a'b $(touch pwned); c")
    hostile = Path.join(project, "x\e[2J\ny")

    for dir <- [quoted, hostile] do
      write(dir, ".mcp.json", %{"mcpServers" => %{"s" => %{"command" => "srv"}}})
    end

    [%Check{remediation: remediation}] = McpProjectTrust.run(project_dir: quoted)
    [_, argument] = Regex.run(~r/lemon mcp trust --cwd (.+)`/, remediation)
    assert {^quoted, 0} = System.cmd("sh", ["-c", "printf %s " <> argument], cd: project)
    refute File.exists?(Path.join(project, "pwned"))

    [%Check{message: message, remediation: remediation}] =
      McpProjectTrust.run(project_dir: hostile)

    refute String.contains?(message <> remediation, ["\e", "\n"])
    refute remediation =~ "--cwd"
  end

  defp write(dir, relative, document) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(document))
  end
end
