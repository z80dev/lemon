defmodule LemonWeb.BlueprintManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonAutomation.{CronManager, CronStore}
  alias LemonCore.ProfileStore

  setup do
    marker = "PLANTED_WEB_BLUEPRINT_#{System.unique_integer([:positive, :monotonic])}"

    root =
      Path.join(
        System.tmp_dir!(),
        "private_blueprint_#{marker}_#{System.unique_integer([:positive, :monotonic])}"
      )

    state = Path.join(root, "state")
    profile_opts = [home_state_dir: state, config_path: Path.join(state, "config.toml")]
    catalog = Path.join(state, "bundles")
    File.mkdir_p!(catalog)

    profile_id = unique_id("web-profile")
    bundle_id = unique_id("web-bundle")
    automation_id = unique_id("web-job")
    token = "web-blueprint-token-#{marker}"

    assert {:ok, profile} = ProfileStore.create(%{id: profile_id}, profile_opts)

    bundle =
      write_bundle(catalog, bundle_id, automation_id, marker,
        prompt: "#{marker} prompt content must never reach Web state"
      )

    previous_web =
      Map.new([:access_token, :blueprint_opts, :blueprint_catalog_fun], fn key ->
        {key, Application.get_env(:lemon_web, key)}
      end)

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :blueprint_opts, profile_opts: profile_opts)
    Application.delete_env(:lemon_web, :blueprint_catalog_fun)

    on_exit(fn ->
      Enum.each(previous_web, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)

      CronManager.list()
      |> Enum.filter(&(get_in(&1.meta, ["blueprint", "bundleId"]) == bundle_id))
      |> Enum.each(&CronManager.remove(&1.id))

      File.rm_rf!(root)
    end)

    %{
      automation_id: automation_id,
      bundle: bundle,
      bundle_id: bundle_id,
      catalog: catalog,
      marker: marker,
      profile: profile,
      profile_id: profile_id,
      profile_opts: profile_opts,
      root: root,
      token: token
    }
  end

  test "route fails closed, strips query token, and is discoverable without leaking it", ctx do
    Application.delete_env(:lemon_web, :access_token)

    assert get(build_conn(), "/manage/blueprints") |> response(503) ==
             "Management access token is not configured"

    Application.put_env(:lemon_web, :access_token, ctx.token)
    assert get(build_conn(), "/manage/blueprints?token=wrong") |> response(401) == "Unauthorized"

    {conn, log} =
      with_log(fn -> get(build_conn(), "/manage/blueprints?view=catalog&token=#{ctx.token}") end)

    assert redirected_to(conn, 302) == "/manage/blueprints?view=catalog"
    refute response(conn, 302) =~ ctx.token
    refute log =~ ctx.token

    conn = conn |> recycle() |> get("/manage/blueprints?view=catalog")
    html = html_response(conn, 200)
    assert html =~ "Automation blueprints"
    assert Regex.match?(~r/<meta name="csrf-token" content="[^"]+"\s*\/?>/, html)
    refute html =~ ctx.token
    refute html =~ ctx.marker
    refute html =~ ctx.root

    sessions_conn = get(build_conn(), "/manage?token=#{ctx.token}")
    sessions_html = sessions_conn |> recycle() |> get("/manage") |> html_response(200)
    assert sessions_html =~ ~s(href="/manage/blueprints")
  end

  test "list, inspect, validate, and preview retain only content-free allowlisted state", ctx do
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/blueprints")

    assert html =~ ctx.bundle_id
    refute_sensitive(html, ctx)

    inspected = render_click(view, "inspect", %{"bundle" => ctx.bundle_id})
    assert inspected =~ "metadata inspected"
    refute inspected =~ ctx.profile_id
    refute_sensitive(inspected, ctx)

    validated = render_click(view, "validate")
    assert validated =~ "deterministic audit checks"
    assert validated =~ "Audit pass"
    refute_sensitive(validated, ctx)

    before_jobs = CronManager.list() |> Enum.map(& &1.id) |> MapSet.new()
    skill_file = Path.join(ctx.profile["paths"]["skills"], "safe-note/SKILL.md")
    refute File.exists?(skill_file)

    previewed =
      render_submit(view, "preview", %{"preview" => %{"profile_id" => ctx.profile_id}})

    assert previewed =~ "Exact activation preview is ready"
    assert previewed =~ "No profile or schedule state changed"
    assert Regex.match?(~r/[a-f0-9]{64}/, previewed)
    assert CronManager.list() |> Enum.map(& &1.id) |> MapSet.new() == before_jobs
    refute File.exists?(skill_file)
    refute_sensitive(previewed, ctx)
    refute_sensitive(formatted_live_view_state(view), ctx)
  end

  test "wrong digest mutates nothing, exact activation creates once, and replay is unchanged",
       ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/blueprints")
    render_click(view, "inspect", %{"bundle" => ctx.bundle_id})

    previewed =
      render_submit(view, "preview", %{"preview" => %{"profile_id" => ctx.profile_id}})

    digest = confirmation_digest(previewed)
    before_jobs = matching_jobs(ctx.bundle_id)

    wrong =
      render_submit(view, "activate", %{
        "activation" => %{"confirmation_digest" => String.duplicate("0", 64)}
      })

    assert wrong =~ "Exact digest did not match"
    assert wrong =~ digest
    assert matching_jobs(ctx.bundle_id) == before_jobs
    refute File.exists?(Path.join(ctx.profile["paths"]["skills"], "safe-note/SKILL.md"))

    {activated, activation_log} =
      with_log(fn ->
        render_submit(view, "activate", %{
          "activation" => %{"confirmation_digest" => digest}
        })
      end)

    assert activated =~ "Blueprint activated"
    assert activated =~ "created"
    assert length(matching_jobs(ctx.bundle_id)) == 1
    assert File.exists?(Path.join(ctx.profile["paths"]["skills"], "safe-note/SKILL.md"))
    refute_sensitive(activated, ctx)
    refute_sensitive(activation_log, ctx)

    assert %{} = job = hd(matching_jobs(ctx.bundle_id))
    assert CronStore.get_job(job.id).prompt =~ ctx.marker

    replay_preview =
      render_submit(view, "preview", %{"preview" => %{"profile_id" => ctx.profile_id}})

    assert replay_preview =~ "unchanged schedule action"
    replay_digest = confirmation_digest(replay_preview)

    replayed =
      render_submit(view, "activate", %{
        "activation" => %{"confirmation_digest" => replay_digest}
      })

    assert replayed =~ "already active with identical content"
    assert replayed =~ "unchanged"
    assert length(matching_jobs(ctx.bundle_id)) == 1
    refute_sensitive(replayed, ctx)
    refute_sensitive(formatted_live_view_state(view), ctx)
  end

  test "stale catalog content fails closed, clears preview, and preserves the profile draft",
       ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/blueprints")
    render_click(view, "inspect", %{"bundle" => ctx.bundle_id})

    previewed =
      render_submit(view, "preview", %{"preview" => %{"profile_id" => ctx.profile_id}})

    digest = confirmation_digest(previewed)
    manifest_path = Path.join(ctx.bundle, "bundle.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    changed = put_in(manifest, ["automations", Access.at(0), "prompt"], "changed safe prompt")
    File.write!(manifest_path, Jason.encode!(changed, pretty: true))

    rendered =
      render_submit(view, "activate", %{
        "activation" => %{"confirmation_digest" => digest}
      })

    assert rendered =~ "activation plan changed"
    assert rendered =~ ~s(value="#{ctx.profile_id}")
    refute rendered =~ ~s(id="blueprint-activation-preview")
    assert matching_jobs(ctx.bundle_id) == []
    refute File.exists?(Path.join(ctx.profile["paths"]["skills"], "safe-note/SKILL.md"))
    refute_sensitive(rendered, ctx)
  end

  test "forged IDs and runtime errors stay bounded and content-free", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/blueprints")

    forged = render_click(view, "inspect", %{"bundle" => "../#{ctx.bundle_id}"})
    assert forged =~ "no longer available"
    refute forged =~ ".."

    secret = "RUNTIME_PRIVATE_#{ctx.marker}"

    Application.put_env(:lemon_web, :blueprint_catalog_fun, fn _action, _args ->
      {:error, {:failed, "#{secret} #{ctx.root} bearer-token env command prompt body"}}
    end)

    {rendered, log} =
      with_log(fn ->
        {:ok, failed_view, html} = live(authenticated_conn(ctx.token), "/manage/blueprints")
        {html, formatted_live_view_state(failed_view)}
      end)

    assert {html, state} = rendered
    assert html =~ "catalog is temporarily unavailable"
    refute html =~ secret
    refute state =~ secret
    refute log =~ secret
    refute html =~ ctx.root
    refute state =~ ctx.root
    refute log =~ ctx.root
  end

  defp authenticated_conn(token) do
    conn = get(build_conn(), "/manage/blueprints?token=#{token}")
    assert redirected_to(conn, 302) == "/manage/blueprints"
    conn |> recycle() |> get("/manage/blueprints")
  end

  defp matching_jobs(bundle_id) do
    CronManager.list()
    |> Enum.filter(&(get_in(&1.meta, ["blueprint", "bundleId"]) == bundle_id))
  end

  defp confirmation_digest(html) do
    [digest] =
      Regex.run(~r/id="blueprint-confirmation-digest"[^>]*>\s*([a-f0-9]{64})\s*</, html,
        capture: :all_but_first
      )

    digest
  end

  defp formatted_live_view_state(view) do
    state = :sys.get_state(view.pid)
    Phoenix.LiveView.Channel.format_status(:terminate, [[], state]) |> inspect()
  end

  defp refute_sensitive(text, ctx) do
    refute text =~ ctx.marker
    refute text =~ ctx.root
    refute text =~ "prompt content must never reach Web state"
    refute text =~ "skill body must never reach Web state"
    refute text =~ "private description"
    refute text =~ "private automation name"
  end

  defp write_bundle(root, bundle_id, automation_id, marker, opts) do
    bundle = Path.join(root, bundle_id)
    skill = Path.join([bundle, "skills", "safe-note"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      """
      ---
      name: safe-note
      description: Harmless note workflow
      ---

      # Safe note

      #{marker} skill body must never reach Web state.
      Summarize completed work without external changes.
      """
    )

    manifest = %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "id" => bundle_id,
      "name" => "#{marker} private bundle name",
      "description" => "#{marker} private description",
      "skills" => [%{"key" => "safe-note", "path" => "skills/safe-note"}],
      "automations" => [
        %{
          "id" => automation_id,
          "kind" => "cron",
          "name" => "#{marker} private automation name",
          "schedule" => "0 0 1 1 *",
          "prompt" => Keyword.fetch!(opts, :prompt),
          "enabled" => false,
          "timezone" => "UTC"
        }
      ]
    }

    File.write!(Path.join(bundle, "bundle.json"), Jason.encode!(manifest, pretty: true))
    bundle
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
