defmodule LemonWeb.ProfileManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import ExUnit.CaptureLog
  import LemonWeb.Test.OperatorAuth
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias LemonCore.ProfileStore
  alias Phoenix.LiveView.Channel

  setup :configure_operator_token

  setup do
    marker = "PLANTED_PROFILE_SECRET_#{System.unique_integer([:positive, :monotonic])}"

    root =
      Path.join(
        System.tmp_dir!(),
        "lemon_web_profiles_#{marker}_#{System.unique_integer([:positive, :monotonic])}"
      )

    state = Path.join(root, "state")
    config = Path.join(state, "config.toml")
    opts = [home_state_dir: state, config_path: config]
    File.mkdir_p!(state)

    assert {:ok, profile} =
             ProfileStore.create(
               %{
                 id: "research",
                 name: "Research",
                 model: "openai:gpt-5",
                 systemPrompt: "#{marker} prompt must not enter Web state",
                 node: "local"
               },
               opts
             )

    # The page writes through profiles.* with the runtime's default store, so
    # point the runtime paths (not a Web-only seam) at this test's store.
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)
    sync_router_profiles()

    on_exit(fn ->
      case previous_paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      sync_router_profiles()
      File.rm_rf!(root)
    end)

    %{config: config, marker: marker, opts: opts, profile: profile, root: root}
  end

  test "requires operator auth and links each profile to its stable chat", ctx do
    assert get(build_conn(), "/profiles") |> redirected_to(302) =~ "/login"
    assert get(build_conn(), "/profiles/research/export") |> redirected_to(302) =~ "/login"

    html = ctx.conn |> get("/profiles") |> html_response(200)
    assert html =~ "Profiles"
    assert html =~ "Research"
    assert html =~ ~s(href="/chat/agent%3Aresearch%3Amain")
    refute html =~ "/manage"
    refute_sensitive(html, ctx)
  end

  test "create is preview-first, idempotent, bounded, and opens one stable chat", ctx do
    {:ok, view, html} = live(ctx.conn, "/profiles")
    assert html =~ "1 durable"
    original = File.read!(ctx.config)

    render_click(view, "open-create")
    assert has_element?(view, "#profile-create-form")

    invalid =
      render_submit(view, "preview-create", %{
        "profile" => %{"id" => "../escape", "name" => "Bad", "model" => "", "node" => "local"}
      })

    assert invalid =~ "Use 1–64 lowercase"
    assert File.read!(ctx.config) == original

    preview =
      view
      |> form("#profile-create-form",
        profile: %{
          id: "builder",
          name: "Builder",
          model: "anthropic:claude-sonnet",
          node: "local"
        }
      )
      |> render_submit()

    assert preview =~ "Preview ready"
    assert preview =~ "No profile or filesystem state changed"
    assert preview =~ "Create profile builder"
    assert has_element?(view, "#profile-change-preview")
    assert File.read!(ctx.config) == original
    assert {:error, :not_found} = ProfileStore.get("builder", ctx.opts)

    applied = view |> form("#profile-change-preview-form") |> render_submit()
    assert applied =~ "Profile builder created"
    assert applied =~ "2 durable"
    assert applied =~ ~s(href="/chat/agent%3Abuilder%3Amain")
    refute has_element?(view, "#profile-create-form")
    assert {:ok, created} = ProfileStore.get("builder", ctx.opts)
    assert created["model"] == "anthropic:claude-sonnet"
    assert File.dir?(created["paths"]["workspace"])

    replay = render_submit(view, "apply-preview", %{})
    assert replay =~ "Preview an exact profile change"
    assert length(ProfileStore.list(ctx.opts)) == 2
    refute_sensitive(formatted_live_view_state(view), ctx)
  end

  test "clone and rename bind a fresh revision and preserve drafts on stale refusal", ctx do
    {:ok, view, _html} = live(ctx.conn, "/profiles")

    clone_preview =
      view
      |> form("#profile-clone-form",
        clone: %{
          id: "research-copy",
          name: "Research Copy",
          model: "openai:gpt-5",
          node: "local"
        }
      )
      |> render_submit()

    assert clone_preview =~ "Clone research as research-copy"
    assert {:error, :not_found} = ProfileStore.get("research-copy", ctx.opts)

    cloned = render_submit(view, "apply-preview", %{})
    assert cloned =~ "Profile research-copy cloned"
    assert {:ok, copy} = ProfileStore.get("research-copy", ctx.opts)
    assert copy["canonicalSessionKey"] == "agent:research-copy:main"

    view |> element("#profile-research") |> render_click()

    rename_preview =
      view
      |> form("#profile-rename-form", rename: %{name: "Research Prime"})
      |> render_submit()

    assert rename_preview =~ "Rename profile research"
    assert {:ok, _} = ProfileStore.rename("research", "Changed Elsewhere", ctx.opts)

    stale = render_submit(view, "apply-preview", %{})
    assert stale =~ "That profile changed"
    refute has_element?(view, "#profile-change-preview")
    assert stale =~ ~s(value="Research Prime")
    assert {:ok, %{"name" => "Changed Elsewhere"}} = ProfileStore.get("research", ctx.opts)

    fresh = render_submit(view, "preview-rename", %{"rename" => %{"name" => "Research Prime"}})
    assert fresh =~ "Preview ready"
    renamed = render_submit(view, "apply-preview", %{})
    assert renamed =~ "stable chat did not change"
    assert renamed =~ ~s(href="/chat/agent%3Aresearch%3Amain")
    assert {:ok, %{"name" => "Research Prime"}} = ProfileStore.get("research", ctx.opts)
  end

  test "recoverable delete requires exact ID, rejects stale state, and moves the home to trash",
       ctx do
    {:ok, view, _html} = live(ctx.conn, "/profiles")
    original_home = ctx.profile["paths"]["home"]

    view |> element("button", "Delete profile…") |> render_click()
    assert has_element?(view, "#profile-change-preview", "Recoverable delete")
    assert has_element?(view, "#profile-change-preview-confirmation")
    assert has_element?(view, "#profile-change-preview label span", "research")

    wrong =
      view
      |> form("#profile-change-preview-form", confirmation: "Research")
      |> render_submit()

    assert wrong =~ "Exact profile ID did not match"
    assert has_element?(view, "#profile-change-preview")
    assert File.dir?(original_home)
    assert {:ok, _} = ProfileStore.get("research", ctx.opts)

    assert {:ok, _} = ProfileStore.rename("research", "Concurrent", ctx.opts)

    stale = render_submit(view, "apply-preview", %{"confirmation" => "research"})
    assert stale =~ "preview deletion again"
    assert File.dir?(original_home)

    render_click(view, "preview-delete", %{"id" => "research"})

    deleted = render_submit(view, "apply-preview", %{"confirmation" => "research"})
    assert deleted =~ "moved to Lemon trash"
    assert {:error, :not_found} = ProfileStore.get("research", ctx.opts)
    refute File.exists?(original_home)

    trash = Path.join(ctx.root, "state/trash/profiles")
    assert {:ok, names} = File.ls(trash)
    assert Enum.any?(names, &String.starts_with?(&1, "research-"))
  end

  test "export downloads a credential-safe snapshot without managed paths", ctx do
    conn = get(ctx.conn, "/profiles/research/export")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "lemon-profile-research.json"

    export = Jason.decode!(body)
    assert export["format"] == "lemon-profile"
    assert export["profile"]["id"] == "research"
    assert export["exportPolicy"]["includesSecrets"] == false
    refute body =~ ctx.root
    refute body =~ ctx.profile["paths"]["home"]

    assert get(ctx.conn, "/profiles/missing/export") |> response(404) == "Profile not found"
    assert get(ctx.conn, "/profiles/..%2Fescape/export") |> response(404) == "Profile not found"
  end

  test "system prompts, paths, service reasons, and credentials never enter Web output or state",
       ctx do
    {:ok, view, html} = live(ctx.conn, "/profiles")
    refute_sensitive(html, ctx)
    refute_sensitive(formatted_live_view_state(view), ctx)

    secret = "#{ctx.marker}_RUNTIME_REASON"

    # An unreadable store whose bytes carry private text.
    File.write!(ctx.config, "[profiles.research\n#{secret} = \"#{ctx.root} bearer credential\"\n")

    {rendered, log} = with_log(fn -> render_click(view, "refresh") end)

    assert rendered =~ "0 durable"
    assert rendered =~ "No profiles yet"
    refute rendered =~ secret
    refute log =~ secret
    refute rendered =~ ctx.root
    refute formatted_live_view_state(view) =~ secret
    refute formatted_live_view_state(view) =~ ctx.root
  end

  describe "router profile cache" do
    alias LemonRouter.{AgentProfiles, SubmissionBuilder}

    test "a Web delete reloads the cache and the profile is no longer routable", ctx do
      assert AgentProfiles.exists?("research")
      assert {:ok, _} = build_submission("research")

      {:ok, view, _html} = live(ctx.conn, "/profiles")
      render_click(view, "preview-delete", %{"id" => "research"})
      deleted = render_submit(view, "apply-preview", %{"confirmation" => "research"})
      assert deleted =~ "moved to Lemon trash"

      refute AgentProfiles.exists?("research")
      assert {:error, {:unknown_agent_id, "research"}} = build_submission("research")
    end

    test "Web create, clone and rename are visible to the router at once", ctx do
      {:ok, view, _html} = live(ctx.conn, "/profiles")

      render_submit(view, "preview-create", %{
        "profile" => %{"id" => "builder", "name" => "Builder", "model" => "", "node" => "local"}
      })

      assert render_submit(view, "apply-preview", %{}) =~ "Profile builder created"
      assert AgentProfiles.exists?("builder")

      view |> element("#profile-research") |> render_click()

      render_submit(view, "preview-clone", %{
        "clone" => %{"id" => "research-copy", "name" => "Copy", "model" => "", "node" => "local"}
      })

      assert render_submit(view, "apply-preview", %{}) =~ "cloned"
      assert AgentProfiles.exists?("research-copy")

      view |> element("#profile-research") |> render_click()
      render_submit(view, "preview-rename", %{"rename" => %{"name" => "Research Prime"}})
      assert render_submit(view, "apply-preview", %{}) =~ "renamed"
      assert AgentProfiles.get("research").name == "Research Prime"
    end

    test "a delete missed while the cache process was down is not resurrected on restart",
         ctx do
      # Prime both the registry and the config cache with the profile, with the
      # production TTL (tests run with 0) so the cache entry is served unchecked.
      key = {LemonCore.ConfigCache, :defaults}
      previous = :persistent_term.get(key, nil)
      :persistent_term.put(key, %{mtime_check_interval_ms: 60_000, call_timeout_ms: 5_000})

      try do
        assert AgentProfiles.exists?("research")
        _ = LemonCore.Config.cached(File.cwd!())

        :ok = Supervisor.terminate_child(LemonRouter.Supervisor, AgentProfiles)

        try do
          assert {:ok, _} =
                   ProfileStore.delete("research", Keyword.put(ctx.opts, :confirm, "research"))
        after
          {:ok, _pid} = Supervisor.restart_child(LemonRouter.Supervisor, AgentProfiles)
        end

        refute AgentProfiles.exists?("research")
        assert {:error, {:unknown_agent_id, "research"}} = build_submission("research")
      after
        if previous,
          do: :persistent_term.put(key, previous),
          else: :persistent_term.erase(key)
      end
    end

    test "any ProfileStore writer reloads the cache, not only RPC callers", ctx do
      assert AgentProfiles.exists?("research")

      assert {:ok, _} =
               ProfileStore.delete("research", Keyword.put(ctx.opts, :confirm, "research"))

      refute AgentProfiles.exists?("research")
      assert {:error, {:unknown_agent_id, "research"}} = build_submission("research")
    end

    test "the page and export make no direct ProfileStore calls" do
      for file <- ["live/profile_management_live.ex", "controllers/profile_export_controller.ex"] do
        source = File.read!(Path.expand("../../lib/lemon_web/" <> file, __DIR__))
        refute source =~ "ProfileStore", file
        refute source =~ ":profile_store_", file
      end
    end

    defp build_submission(agent_id) do
      SubmissionBuilder.build(
        LemonCore.RunRequest.new(%{
          origin: :control_plane,
          session_key: "agent:#{agent_id}:main",
          agent_id: agent_id,
          prompt: "Hello",
          run_id: "run_#{System.unique_integer([:positive])}"
        }),
        %{
          run_supervisor: LemonRouter.RunSupervisor,
          run_process_module: LemonRouter.RunProcess,
          run_process_opts: %{notify_pid: self()}
        }
      )
    end
  end

  defp sync_router_profiles do
    LemonRouter.AgentProfiles.reload()
    _ = LemonRouter.AgentProfiles.list()
    :ok
  end

  defp formatted_live_view_state(view) do
    state = :sys.get_state(view.pid)
    Channel.format_status(:terminate, [[], state]) |> inspect(limit: :infinity)
  end

  defp refute_sensitive(text, ctx) do
    refute text =~ ctx.marker
    refute text =~ ctx.root
    refute text =~ "prompt must not enter Web state"
    refute text =~ ctx.profile["paths"]["home"]
    refute text =~ ctx.profile["paths"]["workspace"]
  end
end
