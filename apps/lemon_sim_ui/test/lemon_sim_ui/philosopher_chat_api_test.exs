defmodule LemonSimUi.PhilosopherChatApiTest do
  use LemonSimUi.ConnCase

  alias LemonSimUi.PhilosopherChat

  setup do
    keys = [
      :philosopher_chat_enabled,
      :philosopher_chat_password,
      :philosopher_chat_modules,
      :philosopher_chat_data_root
    ]

    previous = Enum.map(keys, fn key -> {key, Application.get_env(:lemon_sim_ui, key)} end)

    Application.put_env(:lemon_sim_ui, :philosopher_chat_enabled, true)
    Application.put_env(:lemon_sim_ui, :philosopher_chat_password, "test-password")
    # No AI turns in API tests.
    Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, nil)

    tmp =
      Path.join(System.tmp_dir!(), "philosopher_chat_api_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:lemon_sim_ui, :philosopher_chat_data_root, tmp)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:lemon_sim_ui, key),
          else: Application.put_env(:lemon_sim_ui, key, value)
      end)

      cleanup_threads()
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp cleanup_threads do
    {:ok, threads} = PhilosopherChat.list_threads()

    Enum.each(threads, fn thread ->
      PhilosopherChat.delete_thread(thread.id)
    end)
  end

  defp authed(conn) do
    {:ok, token} = PhilosopherChat.Auth.login("test-password")
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp create_thread(conn, name \\ "The Symposium", members \\ ["socrates", "nietzsche"]) do
    conn
    |> authed()
    |> post("/api/chat/threads", %{"name" => name, "member_ids" => members})
    |> json_response(201)
  end

  describe "session" do
    test "wrong password is rejected", %{conn: conn} do
      conn = post(conn, "/api/chat/session", %{"password" => "nope"})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "correct password returns a token", %{conn: conn} do
      conn = post(conn, "/api/chat/session", %{"password" => "test-password"})
      body = json_response(conn, 200)
      assert is_binary(body["token"])
      assert body["user"] == %{"id" => "you", "name" => "You"}
    end

    test "login attempts are rate limited per IP", %{conn: conn} do
      # Start from a clean bucket (other tests in this file post bad
      # passwords from the same Plug.Test remote_ip), and leave it clean.
      PhilosopherChat.Auth.reset_login_attempts({127, 0, 0, 1})
      on_exit(fn -> PhilosopherChat.Auth.reset_login_attempts({127, 0, 0, 1}) end)

      for _ <- 1..5 do
        conn = post(conn, "/api/chat/session", %{"password" => "nope"})
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
      end

      conn = post(conn, "/api/chat/session", %{"password" => "nope"})
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
    end

    test "a successful login resets the attempt bucket", %{conn: conn} do
      PhilosopherChat.Auth.reset_login_attempts({127, 0, 0, 1})

      for _ <- 1..4 do
        conn = post(conn, "/api/chat/session", %{"password" => "nope"})
        assert json_response(conn, 401)
      end

      conn = post(conn, "/api/chat/session", %{"password" => "test-password"})
      assert json_response(conn, 200)["token"]

      # Bucket cleared by the success: the next failures count from zero.
      for _ <- 1..4 do
        conn = post(conn, "/api/chat/session", %{"password" => "nope"})
        assert json_response(conn, 401)
      end

      on_exit(fn -> PhilosopherChat.Auth.reset_login_attempts({127, 0, 0, 1}) end)
    end
  end

  describe "stream tickets" do
    test "issues a ticket without a token (open access)", %{conn: conn} do
      body = post(conn, "/api/chat/stream-ticket") |> json_response(200)
      assert is_binary(body["ticket"])
    end

    test "issues a ticket that verifies", %{conn: conn} do
      body = conn |> authed() |> post("/api/chat/stream-ticket") |> json_response(200)
      assert is_binary(body["ticket"])
      assert {:ok, "user"} = PhilosopherChat.Auth.verify_stream_ticket(body["ticket"])
    end
  end

  describe "roster" do
    test "is public without a token", %{conn: conn} do
      body = get(conn, "/api/chat/roster") |> json_response(200)
      assert length(body["contacts"]) == 18
    end

    test "returns the persona contacts", %{conn: conn} do
      body = conn |> authed() |> get("/api/chat/roster") |> json_response(200)
      assert length(body["contacts"]) == 18

      socrates = Enum.find(body["contacts"], &(&1["id"] == "socrates"))
      assert socrates["name"] == "Socrates"
      assert socrates["emoji"] != nil
      assert socrates["doctrine"] != nil
      assert socrates["relationships"] != nil
    end
  end

  describe "cors" do
    test "responses carry allow-origin headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://z80.wtf")
        |> post("/api/chat/session", %{"password" => "nope"})

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "preflight OPTIONS returns 204 with allow headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://z80.wtf")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/api/chat/threads")

      assert response(conn, 204) == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert ["GET, POST, OPTIONS"] = get_resp_header(conn, "access-control-allow-methods")

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "authorization, content-type"
             ]
    end

    test "configured origin list echoes only matching origins", %{conn: conn} do
      Application.put_env(:lemon_sim_ui, :philosopher_chat_cors_origins, "https://z80.wtf")

      on_exit(fn -> Application.delete_env(:lemon_sim_ui, :philosopher_chat_cors_origins) end)

      allowed =
        conn
        |> put_req_header("origin", "https://z80.wtf")
        |> options("/api/chat/threads")

      assert get_resp_header(allowed, "access-control-allow-origin") == ["https://z80.wtf"]
      assert get_resp_header(allowed, "vary") == ["Origin"]

      rejected =
        conn
        |> recycle()
        |> put_req_header("origin", "https://evil.example")
        |> options("/api/chat/threads")

      assert get_resp_header(rejected, "access-control-allow-origin") == ["null"]
    end
  end

  describe "threads" do
    test "create, list, and get", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn)

      listed = conn |> authed() |> get("/api/chat/threads") |> json_response(200)
      summary = Enum.find(listed["threads"], &(&1["id"] == thread_id))
      assert summary["name"] == "The Symposium"
      assert summary["status"] == "active"
      assert summary["message_count"] == 0

      shown = conn |> authed() |> get("/api/chat/threads/#{thread_id}") |> json_response(200)
      assert shown["thread"]["id"] == thread_id
      assert shown["thread"]["messages"] == []
      assert length(shown["thread"]["members"]) == 3
    end

    test "rejects invalid creates", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post("/api/chat/threads", %{"name" => "  ", "member_ids" => ["socrates"]})
        |> json_response(400)

      assert body["error"] == "Name is required"

      body =
        conn
        |> authed()
        |> post("/api/chat/threads", %{"name" => "Bad", "member_ids" => ["zeus"]})
        |> json_response(400)

      assert body["error"] == "Unknown philosopher"
    end

    test "malformed create bodies return 400, not 500", %{conn: conn} do
      for body <- [
            %{"name" => 1, "member_ids" => ["socrates"]},
            %{"name" => "Bad", "member_ids" => "socrates"},
            %{"name" => "Bad", "member_ids" => [1, 2]},
            %{"name" => "Bad", "member_ids" => ["socrates"], "pace" => "frantic"}
          ] do
        response =
          conn
          |> authed()
          |> post("/api/chat/threads", body)
          |> json_response(400)

        assert response == %{"error" => "Invalid request"}
      end
    end

    test "nudge with a non-binary agent_id returns 400", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Nudge", ["hume"])

      response =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/nudge", %{"agent_id" => 1})
        |> json_response(400)

      assert response == %{"error" => "Invalid request"}
    end

    test "events tolerates malformed since params", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Since", ["plato"])

      body =
        conn
        |> authed()
        |> get("/api/chat/threads/#{thread_id}/events?since[a]=1")
        |> json_response(200)

      assert body["events"] == []

      body =
        conn
        |> authed()
        |> get("/api/chat/threads/#{thread_id}/events?since=-5")
        |> json_response(200)

      assert body["events"] == []
    end

    test "unknown thread id returns 404", %{conn: conn} do
      conn = conn |> authed() |> get("/api/chat/threads/nope")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "posting messages, pause, and resume", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Dialogues", ["plato"])

      posted =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/messages", %{"text" => "What is justice?"})
        |> json_response(200)

      assert posted["duplicate"] == false

      assert [%{"author" => "you", "text" => "What is justice?", "seq" => 1}] =
               posted["thread"]["messages"]

      paused =
        conn |> authed() |> post("/api/chat/threads/#{thread_id}/pause") |> json_response(200)

      assert paused["status"] == "paused"

      rejected =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/messages", %{"text" => "hello?"})
        |> json_response(400)

      assert rejected["error"] == "Thread is not active"

      resumed =
        conn |> authed() |> post("/api/chat/threads/#{thread_id}/resume") |> json_response(200)

      assert resumed["status"] == "active"
    end

    test "rejects empty messages", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Empty", ["plato"])

      body =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/messages", %{"text" => "   "})
        |> json_response(400)

      assert body["error"] == "Message is required"
    end

    test "duplicate client_msg_id is idempotent", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Idem", ["plato"])

      first =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/messages", %{
          "text" => "hello",
          "client_msg_id" => "cm-1"
        })
        |> json_response(200)

      assert first["duplicate"] == false

      second =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/messages", %{
          "text" => "hello",
          "client_msg_id" => "cm-1"
        })
        |> json_response(200)

      assert second["duplicate"] == true
      assert length(second["thread"]["messages"]) == 1
    end

    test "nudge schedules an agent", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Nudge", ["hume", "kant"])

      body =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/nudge", %{"agent_id" => "kant"})
        |> json_response(200)

      assert body["scheduled"] == "kant"

      bad =
        conn
        |> authed()
        |> post("/api/chat/threads/#{thread_id}/nudge", %{"agent_id" => "zeus"})
        |> json_response(400)

      assert bad["error"] == "Not a member of this thread"
    end

    test "memories returns the agent file list", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Mem", ["marx"])

      body =
        conn
        |> authed()
        |> get("/api/chat/threads/#{thread_id}/memories/marx")
        |> json_response(200)

      assert is_binary(body["memories"]["root"])
      assert is_list(body["memories"]["files"])
    end

    test "events cursor returns broadcasts after since", %{conn: conn} do
      %{"thread_id" => thread_id} = create_thread(conn, "Cursor", ["plato"])

      empty =
        conn |> authed() |> get("/api/chat/threads/#{thread_id}/events") |> json_response(200)

      assert empty["events"] == []
      assert is_binary(empty["epoch"])
      assert empty["latest_seq"] == 0

      conn
      |> authed()
      |> post("/api/chat/threads/#{thread_id}/messages", %{"text" => "one"})
      |> json_response(200)

      body =
        conn |> authed() |> get("/api/chat/threads/#{thread_id}/events") |> json_response(200)

      assert [%{"event_seq" => 1, "type" => "message"}] = body["events"]
      assert body["latest_seq"] == 1
      assert body["epoch"] == empty["epoch"]

      body =
        conn
        |> authed()
        |> get("/api/chat/threads/#{thread_id}/events?since=1")
        |> json_response(200)

      assert body["events"] == []
    end
  end
end
