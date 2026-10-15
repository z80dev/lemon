defmodule LemonWeb.LearningLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  @moduletag :tmp_dir

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonCore.ProfileStore
  alias LemonMemory.{Document, Store}
  alias LemonSkills.Timeline

  setup :configure_operator_token

  setup %{tmp_dir: root} do
    store = :"learning_web_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(root, "store")})
    profile_opts = [home_state_dir: Path.join(root, "profiles")]
    {:ok, paths} = ProfileStore.paths("alice", profile_opts)
    home = paths["workspace"]
    File.mkdir_p!(Path.join(home, ".lemon"))
    old = Application.get_env(:lemon_web, :learning_timeline_fun)

    Application.put_env(:lemon_web, :learning_timeline_fun, fn profile, opts ->
      Timeline.for_profile(profile, opts ++ [server: store, profile_opts: profile_opts])
    end)

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_web, :learning_timeline_fun, old),
        else: Application.delete_env(:lemon_web, :learning_timeline_fun)
    end)

    for {id, kind, date, text} <- [
          {"user", "user", ~U[2026-01-01 23:59:00Z], "Prefers short explanations"},
          {"project", "project_learning", ~U[2026-01-02 00:01:00Z], "Run the release checks"},
          {"source", "learned_source", ~U[2026-01-02 01:00:00Z],
           "<img src=x onerror=alert(1)> api_key=sk-test-abcdefghijklmnop https://private.example/path"}
        ] do
      at = DateTime.to_unix(date, :millisecond)

      doc =
        Document.new(
          doc_id: "mem_learning_#{id}",
          agent_id: "alice",
          session_key: "agent:alice:main",
          answer_summary: text,
          outcome: :success,
          started_at_ms: at,
          ingested_at_ms: at,
          meta: %{"kind" => kind, "home_digest" => digest(home), "preference_facts" => [text]}
        )

      :ok = Store.put_sync(store, doc)

      :ok =
        Store.put_sync(store, %{
          doc
          | doc_id: "mem_foreign_#{id}",
            agent_id: "bob",
            answer_summary: "FOREIGN_PROFILE_SECRET"
        })
    end

    File.write!(
      Path.join([home, ".lemon", "skills.usage.json"]),
      Jason.encode!(%{
        "skills" => %{
          "test-skill" => %{
            "created_at" => "2026-01-02T02:00:00Z",
            "created_by_agent_id" => "alice"
          }
        }
      })
    )

    %{home: home, store: store}
  end

  test "requires operator authentication and exposes a Learning navigation entry", %{conn: conn} do
    assert get(build_conn(), "/learning") |> redirected_to(302) =~ "/login"
    html = conn |> get("/learning?profile=alice") |> html_response(200)
    assert html =~ ~s(href="/learning")
    assert html =~ "Learning timeline"
    clear_operator_token()
    assert get(build_conn(), "/learning") |> response(503) =~ "operator token"
  end

  test "connected render groups by UTC day and escapes untrusted redacted previews", %{conn: conn} do
    {:ok, view, html} = live(conn, "/learning?profile=alice")
    assert has_element?(view, "#learning-day-2026-01-02")
    assert has_element?(view, "#learning-day-2026-01-01")
    assert has_element?(view, "#learning-count", "4 events shown")
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    refute html =~ "sk-test-abcdefghijklmnop"
    refute html =~ "private.example"
    refute html =~ "FOREIGN_PROFILE_SECRET"
    assert has_element?(view, "a[href='/memory']", "Memory management")
    assert has_element?(view, "a[href='/skills']", "Skill management")

    [newer, older] =
      Enum.map(
        ["2026-01-02", "2026-01-01"],
        &(String.split(html, "id=\"learning-day-#{&1}\"") |> hd() |> byte_size())
      )

    assert newer < older
  end

  test "kind and profile filters run through the shared model and persist in URL", %{conn: conn} do
    {:ok, view, _} = live(conn, "/learning?profile=alice")

    view
    |> form("#learning-filters", filters: %{profile: "alice", kind: "skill"})
    |> render_change()

    assert_patch(view, "/learning?kind=skill&profile=alice")
    assert has_element?(view, "#learning-count", "1 events shown")
    assert has_element?(view, "li[data-kind='skill']", "test-skill")
    refute has_element?(view, "li[data-kind='project']")

    view
    |> form("#learning-filters", filters: %{profile: "empty-profile", kind: "all"})
    |> render_change()

    assert_patch(view, "/learning?kind=all&profile=empty-profile")
    assert has_element?(view, "#learning-empty")
    refute has_element?(view, "li[data-kind='skill']")
  end

  test "invalid filters never widen scope and storage errors do not look empty", %{
    conn: conn,
    home: home
  } do
    {:ok, view, html} = live(conn, "/learning?profile=../alice&kind=all")
    assert html =~ "Choose a valid local profile"
    refute has_element?(view, "#learning-empty")
    render_click(view, "refresh")
    refute has_element?(view, "#learning-count")

    File.write!(
      Path.join([home, ".lemon", "skills.usage.json"]),
      "not json /private/error token=secret"
    )

    {:ok, failing, html} = live(conn, "/learning?profile=alice")
    assert html =~ "Learning timeline unavailable"
    refute html =~ "/private/error"
    refute has_element?(failing, "#learning-empty")
    File.rm!(Path.join([home, ".lemon", "skills.usage.json"]))
    render_click(failing, "refresh")
    assert has_element?(failing, "#learning-count", "3 events shown")
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
