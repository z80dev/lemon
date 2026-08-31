defmodule LemonWeb.ProfileManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonCore.ProfileStore
  alias Phoenix.LiveView.Channel

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
    token = "web-profile-token-#{System.unique_integer([:positive, :monotonic])}"
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

    previous =
      Map.new([:access_token, :profile_store_opts, :profile_store_fun], fn key ->
        {key, Application.get_env(:lemon_web, key)}
      end)

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :profile_store_opts, opts)
    Application.delete_env(:lemon_web, :profile_store_fun)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{config: config, marker: marker, opts: opts, profile: profile, root: root, token: token}
  end

  test "route fails closed, strips query tokens, and is linked from management", ctx do
    Application.delete_env(:lemon_web, :access_token)

    assert get(build_conn(), "/manage/profiles") |> response(503) ==
             "Management access token is not configured"

    Application.put_env(:lemon_web, :access_token, ctx.token)
    assert get(build_conn(), "/manage/profiles?token=wrong") |> response(401) == "Unauthorized"

    {conn, log} =
      with_log(fn -> get(build_conn(), "/manage/profiles?view=roster&token=#{ctx.token}") end)

    assert redirected_to(conn, 302) == "/manage/profiles?view=roster"
    refute response(conn, 302) =~ ctx.token
    refute log =~ ctx.token

    html = conn |> recycle() |> get("/manage/profiles?view=roster") |> html_response(200)
    assert html =~ "Specialist profiles"
    assert html =~ "Research"
    assert html =~ ~s(href="/sessions/agent%3Aresearch%3Amain")
    assert Regex.match?(~r/<meta name="csrf-token" content="[^"]+"\s*\/?>/, html)
    refute_sensitive(html, ctx)

    sessions_conn = get(build_conn(), "/manage?token=#{ctx.token}")
    sessions_html = sessions_conn |> recycle() |> get("/manage") |> html_response(200)
    assert sessions_html =~ ~s(href="/manage/profiles")
  end

  test "create is preview-first, idempotent, bounded, and opens one stable chat", ctx do
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/profiles")
    assert html =~ "1 durable"
    original = File.read!(ctx.config)

    invalid =
      render_submit(view, "preview-create", %{
        "profile" => %{"id" => "../escape", "name" => "Bad", "model" => "", "node" => "local"}
      })

    assert invalid =~ "Use 1–64 lowercase"
    assert File.read!(ctx.config) == original

    preview =
      render_submit(view, "preview-create", %{
        "profile" => %{
          "id" => "builder",
          "name" => "Builder",
          "model" => "anthropic:claude-sonnet",
          "node" => "local"
        }
      })

    assert preview =~ "Preview ready"
    assert preview =~ "No profile or filesystem state changed"
    assert preview =~ "Create profile builder"
    assert File.read!(ctx.config) == original
    assert {:error, :not_found} = ProfileStore.get("builder", ctx.opts)

    applied = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert applied =~ "Profile builder created"
    assert applied =~ "2 durable"
    assert applied =~ ~s(href="/sessions/agent%3Abuilder%3Amain")
    assert {:ok, created} = ProfileStore.get("builder", ctx.opts)
    assert created["model"] == "anthropic:claude-sonnet"
    assert File.dir?(created["paths"]["workspace"])

    replay = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert replay =~ "Preview an exact profile change"
    assert length(ProfileStore.list(ctx.opts)) == 2
    refute_sensitive(formatted_live_view_state(view), ctx)
  end

  test "clone and rename bind a fresh revision and preserve drafts on stale refusal", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/profiles")

    clone_preview =
      render_submit(view, "preview-clone", %{
        "clone" => %{
          "id" => "research-copy",
          "name" => "Research Copy",
          "model" => "openai:gpt-5",
          "node" => "local"
        }
      })

    assert clone_preview =~ "Clone research as research-copy"
    assert {:error, :not_found} = ProfileStore.get("research-copy", ctx.opts)

    cloned = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert cloned =~ "Profile research-copy cloned"
    assert {:ok, copy} = ProfileStore.get("research-copy", ctx.opts)
    assert copy["canonicalSessionKey"] == "agent:research-copy:main"

    render_click(view, "select", %{"id" => "research"})

    rename_preview =
      render_submit(view, "preview-rename", %{"rename" => %{"name" => "Research Prime"}})

    assert rename_preview =~ "Rename profile research"
    assert {:ok, _} = ProfileStore.rename("research", "Changed Elsewhere", ctx.opts)

    stale = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert stale =~ "That profile changed"
    refute stale =~ ~s(id="profile-change-preview")
    assert stale =~ ~s(value="Research Prime")
    assert {:ok, %{"name" => "Changed Elsewhere"}} = ProfileStore.get("research", ctx.opts)

    fresh = render_submit(view, "preview-rename", %{"rename" => %{"name" => "Research Prime"}})
    assert fresh =~ "Preview ready"
    renamed = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert renamed =~ "stable chat did not change"
    assert renamed =~ ~s(href="/sessions/agent%3Aresearch%3Amain")
    assert {:ok, %{"name" => "Research Prime"}} = ProfileStore.get("research", ctx.opts)
  end

  test "recoverable delete requires exact ID, rejects stale state, and moves the home to trash",
       ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/profiles")
    original_home = ctx.profile["paths"]["home"]

    preview = render_click(view, "preview-delete", %{"id" => "research"})
    assert preview =~ "Recoverable"
    assert preview =~ "<code>research</code>"

    wrong =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "Research"}})

    assert wrong =~ "Exact profile ID did not match"
    assert File.dir?(original_home)
    assert {:ok, _} = ProfileStore.get("research", ctx.opts)

    assert {:ok, _} = ProfileStore.rename("research", "Concurrent", ctx.opts)

    stale =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "research"}})

    assert stale =~ "preview deletion again"
    assert File.dir?(original_home)

    render_click(view, "preview-delete", %{"id" => "research"})

    deleted =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "research"}})

    assert deleted =~ "moved to Lemon trash"
    assert {:error, :not_found} = ProfileStore.get("research", ctx.opts)
    refute File.exists?(original_home)

    trash = Path.join(ctx.root, "state/trash/profiles")
    assert {:ok, names} = File.ls(trash)
    assert Enum.any?(names, &String.starts_with?(&1, "research-"))
  end

  test "system prompts, paths, service reasons, and credentials never enter Web output or state",
       ctx do
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/profiles")
    refute_sensitive(html, ctx)
    refute_sensitive(formatted_live_view_state(view), ctx)

    secret = "#{ctx.marker}_RUNTIME_REASON"

    Application.put_env(:lemon_web, :profile_store_fun, fn
      :list, _args -> [{"not", "a profile"}]
      _action, _args -> {:error, {:private, secret, ctx.root, "bearer credential prompt"}}
    end)

    {rendered, log} =
      with_log(fn -> render_click(view, "refresh") end)

    assert rendered =~ "0 durable"
    refute rendered =~ secret
    refute log =~ secret
    refute rendered =~ ctx.root
    refute formatted_live_view_state(view) =~ secret
    refute formatted_live_view_state(view) =~ ctx.root
  end

  defp authenticated_conn(token) do
    conn = get(build_conn(), "/manage/profiles?token=#{token}")
    assert redirected_to(conn, 302) == "/manage/profiles"
    conn |> recycle() |> get("/manage/profiles")
  end

  defp formatted_live_view_state(view) do
    state = :sys.get_state(view.pid)
    Channel.format_status(:terminate, [[], state]) |> inspect()
  end

  defp refute_sensitive(text, ctx) do
    refute text =~ ctx.marker
    refute text =~ ctx.root
    refute text =~ "prompt must not enter Web state"
    refute text =~ ctx.profile["paths"]["home"]
    refute text =~ ctx.profile["paths"]["workspace"]
  end
end
