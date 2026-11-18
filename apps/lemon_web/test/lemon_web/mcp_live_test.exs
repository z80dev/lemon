defmodule LemonWeb.McpLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonControlPlane.Methods.Registry

  @endpoint LemonWeb.Endpoint

  setup :configure_operator_token

  setup do
    root = Path.join(System.tmp_dir!(), "web-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    Application.put_env(:lemon_skills, :mcp_disabled, false)

    on_exit(fn ->
      Application.delete_env(:lemon_control_plane, :mcp_source)

      if is_nil(disabled),
        do: Application.delete_env(:lemon_skills, :mcp_disabled),
        else: Application.put_env(:lemon_skills, :mcp_disabled, disabled)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp start_source(configs) do
    name = :"web_mcp_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LemonSkills.McpSource, name: name, configs: configs, refresh_interval_ms: 3_600_000}
    )

    Application.put_env(:lemon_control_plane, :mcp_source, name)
    name
  end

  defp fixture(root) do
    script = Path.join(root, "server.exs")

    File.write!(script, ~S'''
    defmodule WebMcpFixture do
      def run, do: IO.stream(:stdio, :line) |> Enum.each(&handle(:json.decode(String.trim(&1))))
      defp handle(%{"method" => "initialize", "id" => id}),
        do: respond(id, %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "fixture", "version" => "1"}})
      defp handle(%{"method" => "tools/list", "id" => id}),
        do: respond(id, %{"tools" => [
          %{"name" => "read_note", "description" => "Read a note", "inputSchema" => %{"type" => "object"}},
          %{"name" => "write_note", "description" => "Write a note", "inputSchema" => %{"type" => "object"}}]})
      defp handle(%{"id" => id}), do: respond(id, %{})
      defp handle(_), do: :ok
      defp respond(id, r), do: IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => r}), "\n"])
    end
    WebMcpFixture.run()
    ''')

    {:stdio, System.find_executable("elixir"), ["--erl", "+S 1:1", script, "--private-flag"],
     name: "notes", env: [{"NOTES_TOKEN", "sk-web-secret"}], approval: :always}
  end

  test "lists connected and failed servers with redacted identity and a tool drawer", %{
    conn: conn,
    root: root
  } do
    source =
      start_source([
        fixture(root),
        {:stdio, Path.join(root, "absent-server"), ["--x"], name: "broken"}
      ])

    :ok = LemonSkills.McpSource.refresh(source)

    {:ok, view, html} = live(conn, "/mcp")

    assert html =~ "notes"
    assert html =~ "Connected"
    assert html =~ "broken"
    assert html =~ "Could not start or reach the server"
    assert html =~ "Approval required"

    for secret <- ["--private-flag", "sk-web-secret", root, "server.exs"] do
      refute html =~ secret
    end

    html = view |> element(~s(button[aria-label="Show tools for notes"])) |> render_click()
    assert has_element?(view, "#mcp-drawer")
    assert html =~ "read_note"
    assert html =~ "Write a note"

    view |> form("#mcp-search-form", %{"q" => "write_note"}) |> render_change()
    assert has_element?(view, ~s(button[aria-label="Show tools for notes"]))
    refute has_element?(view, ~s(button[aria-label="Show tools for broken"]))
  end

  test "reconnect is async and reports the fresh inventory", %{conn: conn, root: root} do
    start_source([fixture(root)])

    {:ok, view, html} = live(conn, "/mcp")
    assert html =~ "Not connected yet"

    view |> element("button[phx-click=reconnect]") |> render_click()
    html = render_async(view, 15_000)

    assert html =~ "Reconnected: 1 of 1 servers online."
    assert html =~ "Connected"
  end

  test "no configured servers shows how to configure them", %{conn: conn} do
    start_source([])
    {:ok, _view, html} = live(conn, "/mcp")

    assert html =~ "No MCP servers configured"
    assert html =~ "lemon mcp add"
    assert html =~ "mcp.json"
    assert html =~ "docs/skills.md"
  end

  test "pending project trust is shown with redacted previews and no grant action", %{
    conn: conn,
    root: root
  } do
    project = Path.join(root, "project")
    saved = Map.new(["LEMON_AGENT_DIR", "LEMON_MCP_SERVERS"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    System.put_env("LEMON_MCP_SERVERS", "[]")
    File.mkdir_p!(Path.join(project, ".lemon"))

    File.write!(
      Path.join(project, ".lemon/mcp.json"),
      Jason.encode!(%{
        "servers" => [
          %{
            "name" => "repo-tool",
            "type" => "stdio",
            "command" => "repo-server",
            "args" => ["--token=sk-abcdefghijklmnop"]
          },
          %{
            "name" => "repo-oauth",
            "type" => "http",
            "url" => "https://o.example/mcp",
            "oauth" => %{"client_id" => "c", "token_secret" => "victim"}
          }
        ]
      })
    )

    name = :"web_mcp_project_#{System.unique_integer([:positive])}"
    start_supervised!({LemonSkills.McpSource, name: name, refresh_interval_ms: 3_600_000})
    assert [] = LemonSkills.McpSource.discover_tools(name, cwd: project)
    Application.put_env(:lemon_control_plane, :mcp_source, name)

    {:ok, view, html} = live(conn, "/mcp")

    assert has_element?(view, "#mcp-project-trust")
    assert html =~ "Untrusted project MCP files"
    assert html =~ ".lemon/mcp.json"
    assert html =~ "repo-tool"
    assert html =~ "repo-server"
    assert html =~ "repo-oauth"
    assert html =~ "lemon mcp trust"
    refute html =~ "sk-abcdefghijklmnop"
    refute has_element?(view, "#mcp-project-trust button")
    assert LemonSkills.McpConfig.project_trust(project) == nil
  end

  test "an unavailable source is not shown as empty", %{conn: conn} do
    Application.put_env(:lemon_control_plane, :mcp_source, :web_mcp_missing)
    {:ok, view, html} = live(conn, "/mcp")

    assert html =~ "MCP status is unavailable"
    refute html =~ "No MCP servers configured"
    assert has_element?(view, "button[phx-click=reconnect][disabled]")
  end

  test "an unregistered method is an unavailable state", %{conn: conn} do
    {:ok, module} = Registry.lookup("mcp.servers.list")
    :ok = Registry.unregister("mcp.servers.list")
    on_exit(fn -> Registry.register(module) end)

    {:ok, _view, html} = live(conn, "/mcp")
    assert html =~ "MCP status is unavailable"
  end
end
