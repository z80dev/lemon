defmodule LemonWeb.SkillsLiveTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises the real skills RPC/registry against temporary user roots and config.
  Global directory overrides and application settings are restored on exit.
  Refresh at both lifecycle boundaries so the registry's identity-check interval
  cannot expose the previous fixture (or the operator's installed skills).
  """

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonControlPlane.Methods.Registry

  @endpoint LemonWeb.Endpoint

  setup :configure_operator_token

  setup do
    root = Path.join(System.tmp_dir!(), "web-skills-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    agent_dir = Path.join(root, "agent")
    hermes = Path.join(root, "hermes")
    File.mkdir_p!(home)

    overrides = %{
      "HOME" => home,
      "LEMON_AGENT_DIR" => agent_dir,
      "LEMON_HARNESS_SKILLS_DIR" => Path.join(root, "harness"),
      "LEMON_OMP_SKILLS_DIR" => Path.join(root, "omp"),
      "LEMON_CLAUDE_SKILLS_DIR" => Path.join(root, "claude")
    }

    env = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)
    hermes_repo = Application.fetch_env(:lemon_skills, :hermes_repo)

    on_exit(fn ->
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case hermes_repo do
        {:ok, value} -> Application.put_env(:lemon_skills, :hermes_repo, value)
        :error -> Application.delete_env(:lemon_skills, :hermes_repo)
      end

      LemonSkills.Registry.refresh()
      File.rm_rf!(root)
    end)

    System.put_env(overrides)
    Application.put_env(:lemon_skills, :hermes_repo, hermes)
    :ok = LemonSkills.Registry.refresh()

    %{root: root, agent_dir: agent_dir, hermes: hermes}
  end

  defp write_skill(dir, key, frontmatter) do
    path = Path.join(dir, key)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\n#{frontmatter}\n---\nBody for #{key}\n")
    LemonSkills.Registry.refresh()
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  describe "installed skills" do
    setup %{agent_dir: agent_dir} do
      skills = Path.join(agent_dir, "skill")

      write_skill(skills, "deploy-helper", """
      name: Deploy Helper
      description: Ship releases safely
      requires:
        bins: [definitely-missing-tool-xyz]
      metadata:
        lemon:
          category: devops
      """)

      write_skill(skills, "notes", "name: Notes\ndescription: Keep notes tidy")
      :ok
    end

    test "lists skills with status and never renders paths", %{conn: conn, root: root} do
      {:ok, view, html} = live(conn, "/skills")

      assert html =~ "Deploy Helper"
      assert html =~ "Ship releases safely"
      assert html =~ "Needs setup"
      assert html =~ "Notes"
      refute html =~ root
      assert has_element?(view, "#skills-search[phx-hook=SearchShortcut]")
      assert has_element?(view, "#skills-list > li#skill-deploy-helper")
      assert has_element?(view, "#skills-list > li#skill-notes")
      assert length(LemonSkills.Registry.list()) == 2
    end

    test "search and state filters narrow the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      view |> form("#skills-search-form", %{"q" => "deploy"}) |> render_change()
      assert has_element?(view, "#skill-deploy-helper")
      refute has_element?(view, "#skill-notes")

      view |> form("#skills-search-form", %{"q" => ""}) |> render_change()
      view |> element("button[phx-value-value=attention]") |> render_click()
      assert has_element?(view, "#skill-deploy-helper")
      refute has_element?(view, "#skill-notes")
    end

    test "detail drawer shows provenance and missing requirements", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, "/skills")

      html = view |> element("#skill-deploy-helper button[phx-click=select]") |> render_click()

      assert has_element?(view, "#skill-drawer")
      assert html =~ "definitely-missing-tool-xyz"
      assert html =~ "devops"
      refute html =~ root
    end

    test "disable and enable go through skills config", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills")

      html = view |> element("#skill-toggle-notes") |> render_click()
      assert html =~ "Notes disabled"
      assert LemonSkills.Config.skill_disabled?("notes")
      assert has_element?(view, ~s(#skill-toggle-notes[aria-checked="false"]))

      view |> element("#skill-toggle-notes") |> render_click()
      refute LemonSkills.Config.skill_disabled?("notes")
      assert has_element?(view, ~s(#skill-toggle-notes[aria-checked="true"]))
    end
  end

  test "empty registry renders the empty state", %{conn: conn} do
    assert LemonSkills.Registry.list() == []
    {:ok, view, _html} = live(conn, "/skills")

    assert has_element?(view, "#skills-installed #skills-search")
    assert has_element?(view, ~s(#skills-installed a[href="/skills?tab=catalog"]))
    refute has_element?(view, "#skills-list")
  end

  test "a failed query is an unavailable state, not an empty list", %{conn: conn} do
    {:ok, module} = Registry.lookup("skills.list")
    :ok = Registry.unregister("skills.list")
    on_exit(fn -> Registry.register(module) end)

    {:ok, view, _html} = live(conn, "/skills")

    assert has_element?(view, "#skills-installed button[phx-click=refresh]")
    refute has_element?(view, "#skills-installed #skills-search")
    refute has_element?(view, ~s(#skills-installed a[href="/skills?tab=catalog"]))
    refute has_element?(view, "#skills-list")
  end

  describe "Hermes catalog" do
    setup %{hermes: hermes} do
      skill = Path.join(hermes, "optional-skills/research/arxiv")
      File.mkdir_p!(skill)

      File.write!(
        Path.join(skill, "SKILL.md"),
        "---\nname: arxiv\ndescription: Search papers.\n---\nbody\n"
      )

      approvals = Application.fetch_env(:lemon_skills, :require_approval)
      Application.put_env(:lemon_skills, :require_approval, true)

      on_exit(fn ->
        case approvals do
          {:ok, value} -> Application.put_env(:lemon_skills, :require_approval, value)
          :error -> Application.delete_env(:lemon_skills, :require_approval)
        end
      end)

      :ok
    end

    test "loads the catalog and installs after inline approval", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills?tab=catalog")
      html = render_async(view)

      assert html =~ "Search papers."
      id = "hermes:optional/research/arxiv"
      view |> element(~s(button[phx-click=install][phx-value-id="#{id}"])) |> render_click()
      assert render(view) =~ "Fetching and auditing"

      eventually(fn -> has_element?(view, "[id^=approval-]") end)
      assert render(view) =~ "Approval needed: install arxiv"
      view |> element("[id^=approval-] button[phx-value-decision=approve_once]") |> render_click()

      eventually(fn -> render(view) =~ "Installed arxiv" end)
      assert {:ok, _entry} = LemonSkills.Registry.get("arxiv")
      refute has_element?(view, "[id^=approval-]")
    end

    test "denied install reports the refusal and allows a manual retry", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/skills?tab=catalog")
      render_async(view)

      view |> element("button[phx-click=install]") |> render_click()
      eventually(fn -> has_element?(view, "[id^=approval-]") end)
      view |> element("[id^=approval-] button[phx-value-decision=deny]") |> render_click()

      eventually(fn -> render(view) =~ "Skill installation was denied" end)
      assert has_element?(view, "button[phx-click=install]", "Retry")
      assert LemonSkills.Registry.get("arxiv") == :error
    end
  end
end
