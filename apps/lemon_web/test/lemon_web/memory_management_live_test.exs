defmodule LemonWeb.MemoryManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonMemory.{Document, Lifecycle, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    marker = "PLANTED_MEMORY_#{System.unique_integer([:positive, :monotonic])}"
    token = "memory-web-token-#{marker}"
    store = String.to_atom("memory_web_#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: store, path: tmp_dir})

    previous =
      Map.new([:access_token, :memory_lifecycle_fun], fn key ->
        {key, Application.get_env(:lemon_web, key)}
      end)

    Application.put_env(:lemon_web, :access_token, token)

    Application.put_env(:lemon_web, :memory_lifecycle_fun, fn action, args ->
      apply(Lifecycle, action, args ++ [[server: store]])
    end)

    learned =
      document("learned", 30,
        agent_id: "reviewer",
        workspace_key: "/Users/private/#{marker}",
        scope: :agent,
        prompt_summary: "Learn from OPENAI_API_KEY in /Users/private/source.md",
        answer_summary: "token=#{marker} https://private.example/path",
        meta: %{
          "kind" => "learned_source",
          "source_digest" => String.duplicate("a", 64),
          "source_count" => 1,
          "source_text_redacted" => true,
          "source_provenance" => [
            %{
              "type" => "file",
              "referenceDigest" => String.duplicate("b", 64),
              "contentDigest" => String.duplicate("c", 64),
              "selectedItems" => 1,
              "selectedBytes" => 320,
              "redactionCount" => 2,
              "rawPath" => "/must/not/render/#{marker}"
            }
          ]
        }
      )

    run =
      document("run", 20,
        prompt_summary: "release health query",
        answer_summary: "Release checks passed."
      )

    :ok = Store.put_sync(store, learned)
    :ok = Store.put_sync(store, run)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    {:ok, learned: learned, marker: marker, run: run, store: store, token: token}
  end

  test "route fails closed, strips query token, and is discoverable", ctx do
    Application.delete_env(:lemon_web, :access_token)

    assert get(build_conn(), "/manage/memory") |> response(503) ==
             "Management access token is not configured"

    Application.put_env(:lemon_web, :access_token, ctx.token)
    assert get(build_conn(), "/manage/memory?token=wrong") |> response(401) == "Unauthorized"

    {conn, log} =
      with_log(fn -> get(build_conn(), "/manage/memory?kind=learned&token=#{ctx.token}") end)

    assert redirected_to(conn, 302) == "/manage/memory?kind=learned"
    refute response(conn, 302) =~ ctx.token
    refute log =~ ctx.token

    html = conn |> recycle() |> get("/manage/memory?kind=learned") |> html_response(200)
    assert html =~ "Durable memory"
    refute_sensitive(html, ctx)

    sessions_html =
      get(build_conn(), "/manage?token=#{ctx.token}")
      |> recycle()
      |> get("/manage")
      |> html_response(200)

    assert sessions_html =~ ~s(href="/manage/memory")
  end

  test "search and inspection render bounded learned provenance without sensitive content", ctx do
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/memory")
    assert html =~ "Reviewed learning"
    assert html =~ "Run memory"
    refute_sensitive(html, ctx)

    searched =
      render_change(view, "search", %{
        "filters" => %{
          "query" => "Release checks",
          "scope" => "all",
          "kind" => "run",
          "agent" => "default",
          "workspace_digest" => "",
          "limit" => "10"
        }
      })

    assert searched =~ "1 shown"
    assert searched =~ ctx.run.doc_id
    refute searched =~ ctx.learned.doc_id

    # Restore the learned filter, then inspect its digest-only provenance.
    render_change(view, "search", %{
      "filters" => %{
        "query" => "",
        "scope" => "agent",
        "kind" => "learned_source",
        "agent" => "reviewer",
        "workspace_digest" => "",
        "limit" => "25"
      }
    })

    inspected = render_click(view, "inspect", %{"id" => ctx.learned.doc_id})
    assert inspected =~ "Reviewed source provenance"
    assert inspected =~ String.duplicate("a", 64)
    assert inspected =~ String.duplicate("b", 64)
    assert inspected =~ "[REDACTED]"
    refute_sensitive(inspected, ctx)
    refute_sensitive(formatted_live_view_state(view), ctx)
  end

  test "wrong and stale confirmations preserve drafts and records; exact digest deletes", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/memory")

    render_change(view, "search", %{
      "filters" => %{
        "query" => "Release checks",
        "scope" => "all",
        "kind" => "run",
        "agent" => "default",
        "workspace_digest" => "",
        "limit" => "10"
      }
    })

    previewed = render_click(view, "preview-delete", %{"id" => ctx.run.doc_id})
    _digest = confirmation_digest(previewed)

    wrong =
      render_submit(view, "confirm-delete", %{
        "delete" => %{"confirmation" => String.duplicate("0", 64)}
      })

    assert wrong =~ "confirmation is stale or incorrect"
    assert wrong =~ ~s(value="Release checks")
    assert {:ok, _} = Store.get_document(ctx.store, ctx.run.doc_id)

    # A changed canonical row invalidates the old digest without deletion.
    changed = %{ctx.run | answer_summary: "Release checks changed.", ingested_at_ms: 21}
    :ok = Store.put_sync(ctx.store, changed)

    previewed = render_click(view, "preview-delete", %{"id" => ctx.run.doc_id})
    stale_digest = confirmation_digest(previewed)
    :ok = Store.put_sync(ctx.store, %{changed | answer_summary: "Release checks changed again."})

    stale =
      render_submit(view, "confirm-delete", %{
        "delete" => %{"confirmation" => stale_digest}
      })

    assert stale =~ "confirmation is stale or incorrect"
    assert stale =~ ~s(value="Release checks")
    assert {:ok, _} = Store.get_document(ctx.store, ctx.run.doc_id)

    fresh = render_click(view, "preview-delete", %{"id" => ctx.run.doc_id})
    fresh_digest = confirmation_digest(fresh)

    deleted =
      render_submit(view, "confirm-delete", %{
        "delete" => %{"confirmation" => fresh_digest}
      })

    assert deleted =~ "exact memory record was deleted"
    assert deleted =~ ~s(value="Release checks")
    assert {:error, :not_found} = Store.get_document(ctx.store, ctx.run.doc_id)
    assert Store.search(ctx.store, "changed again", scope: :all, limit: 10) == []
  end

  test "forged identifiers and arbitrary backend failures stay bounded and sanitized", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/memory")

    forged = render_click(view, "inspect", %{"id" => "../memory.sqlite3"})
    assert forged =~ "temporarily unavailable"
    refute forged =~ "sqlite3"

    Application.put_env(:lemon_web, :memory_lifecycle_fun, fn _action, _args ->
      raise "#{ctx.marker} /Users/private/error.ex https://private.example bearer-token"
    end)

    {rendered, log} =
      with_log(fn ->
        {:ok, failed_view, html} = live(authenticated_conn(ctx.token), "/manage/memory")
        {html, formatted_live_view_state(failed_view)}
      end)

    assert {html, state} = rendered
    assert html =~ "temporarily unavailable"
    refute_sensitive(html, ctx)
    refute_sensitive(state, ctx)
    refute_sensitive(log, ctx)
  end

  defp authenticated_conn(token) do
    conn = get(build_conn(), "/manage/memory?token=#{token}")
    assert redirected_to(conn, 302) == "/manage/memory"
    conn |> recycle() |> get("/manage/memory")
  end

  defp confirmation_digest(html) do
    [digest] =
      Regex.run(~r/id="memory-confirmation-digest"[^>]*>\s*([a-f0-9]{64})\s*</, html,
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
    refute text =~ "/Users/private"
    refute text =~ "private.example"
    refute text =~ "OPENAI_API_KEY"
    refute text =~ "sk-abcdefghijklmnopqrstuvwxyz123456"
    refute text =~ "bearer-token"
  end

  defp document(suffix, ingested_at_ms, overrides) do
    Document.new(
      Map.merge(
        %{
          doc_id: "mem_web_#{suffix}",
          run_id: "run_web_#{suffix}",
          session_key: "agent:default:web-memory",
          agent_id: "default",
          workspace_key: nil,
          scope: :session,
          started_at_ms: ingested_at_ms,
          ingested_at_ms: ingested_at_ms,
          prompt_summary: "Prompt #{suffix}",
          answer_summary: "Answer #{suffix}",
          outcome: :success,
          meta: %{}
        },
        Map.new(overrides)
      )
    )
  end
end
