defmodule CodingAgent.Tools.AskTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Session.UserPrompt
  alias CodingAgent.Tools.Ask
  alias LemonCore.ACPClientBridge

  setup do
    run_id = "ask-test-#{System.unique_integer([:positive])}"
    :ok = ACPClientBridge.register(run_id)
    on_exit(fn -> ACPClientBridge.unregister(run_id) end)
    {:ok, opts: [run_id: run_id, acp_client_elicitation_form: true]}
  end

  test "only negotiated live clients advertise ask", %{opts: opts} do
    assert Ask.available?(opts)
    refute Ask.available?(Keyword.put(opts, :acp_client_elicitation_form, false))
    refute Ask.available?(Keyword.put(opts, :run_id, "not-registered"))
  end

  test "real bridge request uses the rendered form shape and returns the actual accepted choice",
       %{opts: opts} do
    questions = [
      %{
        "id" => "color",
        "question" => "Choose a color:",
        "options" => [%{"label" => "BLUE"}, %{"label" => "ORANGE"}],
        "recommended" => 1
      }
    ]

    task = Task.async(fn -> Ask.execute("call", %{"questions" => questions}, nil, nil, opts) end)
    assert_receive {:acp_client_request, payload}
    assert payload.method == "elicitation/create"
    assert payload.params["mode"] == "form"
    assert payload.params["requestedSchema"]["properties"]["q0"]["default"] == "ORANGE"
    assert payload.params["requestedSchema"]["properties"]["q0__other"]["type"] == "string"

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref,
       %{"result" => %{"action" => "accept", "content" => %{"q0" => "BLUE"}}}}
    )

    result = Task.await(task)
    refute result.is_error
    assert hd(result.details.results)["selectedOptions"] == ["BLUE"]
  end

  test "declining never selects a recommendation", %{opts: opts} do
    task =
      Task.async(fn ->
        Ask.execute(
          "call",
          %{
            "questions" => [
              %{
                "id" => "q",
                "question" => "Question",
                "options" => [%{"label" => "YES"}],
                "recommended" => 0
              }
            ]
          },
          nil,
          nil,
          opts
        )
      end)

    assert_receive {:acp_client_request, payload}

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref, %{"result" => %{"action" => "decline"}}}
    )

    result = Task.await(task)
    assert result.is_error
    assert result.details.status == "declined"
    refute Map.has_key?(result.details, :results)
  end

  test "free text and multiple choices preserve actual custom answers", %{opts: opts} do
    questions = [
      %{"id" => "text", "question" => "Explain", "options" => []},
      %{
        "id" => "multi",
        "question" => "Choose",
        "options" => [%{"label" => "A"}, %{"label" => "B"}],
        "multi" => true
      }
    ]

    task = Task.async(fn -> Ask.execute("call", %{"questions" => questions}, nil, nil, opts) end)
    assert_receive {:acp_client_request, payload}

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref,
       %{
         "action" => "accept",
         "content" => %{"q0" => "Real free text", "q1" => ["B"], "q1__other" => "Custom"}
       }}
    )

    result = Task.await(task)
    refute result.is_error
    assert [text, multi] = result.details.results
    assert text["customInput"] == "Real free text"
    assert text["selectedOptions"] == []
    assert multi["selectedOptions"] == ["B"]
    assert multi["customInput"] == "Custom"
  end

  test "a bound session surface advertises ask and receives real questions without ACP" do
    key = "native-ask-#{System.unique_integer([:positive])}"
    :ok = LemonCore.Bus.subscribe("user_prompts")
    refute Ask.available?(session_key: key)
    assert :ok = UserPrompt.bind(key, self())
    assert Ask.available?(session_key: key)

    question = %{
      "id" => "q",
      "question" => "Choose",
      "options" => [%{"label" => "A"}, %{"label" => "B"}],
      "recommended" => 1
    }

    task =
      Task.async(fn ->
        Ask.execute("call", %{"questions" => [question]}, nil, nil,
          session_key: key,
          run_id: "native-run"
        )
      end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key} = pending
    }

    assert pending["questions"] == [Map.put(question, "multi", false)]
    assert pending["expiresAtMs"] == nil

    assert :ok =
             UserPrompt.resolve(
               pending["promptId"],
               key,
               "native-run",
               %{"action" => "accept", "content" => %{"q0" => "A"}},
               self()
             )

    result = Task.await(task)
    refute result.is_error
    assert hd(result.details.results)["selectedOptions"] == ["A"]

    assert_receive %LemonCore.Event{
      type: :user_prompt_resolved,
      payload: %{"sessionKey" => ^key, "status" => "accept"}
    }

    assert :ok = UserPrompt.unbind(key, self())
    refute Ask.available?(session_key: key)
  end

  test "session questions preserve free text and multi-select answers" do
    key = "native-ask-multi-#{System.unique_integer([:positive])}"
    :ok = LemonCore.Bus.subscribe("user_prompts")
    :ok = UserPrompt.bind(key, self())

    questions = [
      %{"id" => "text", "question" => "Explain", "options" => []},
      %{
        "id" => "multi",
        "question" => "Choose",
        "options" => [%{"label" => "A"}, %{"label" => "B"}],
        "multi" => true
      }
    ]

    task =
      Task.async(fn ->
        Ask.execute("call", %{"questions" => questions}, nil, nil, session_key: key)
      end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key, "promptId" => id}
    }

    assert :ok =
             UserPrompt.resolve(
               id,
               key,
               nil,
               %{
                 "action" => "accept",
                 "content" => %{"q0__other" => "actual text", "q1" => ["B"]}
               },
               self()
             )

    result = Task.await(task)
    refute result.is_error
    assert [text, multi] = result.details.results
    assert text["customInput"] == "actual text"
    assert multi["selectedOptions"] == ["B"]
  end

  test "native registry calls stay read-tier, serialize unanswered forms and reject invented answers" do
    key = "native-ask-registry-#{System.unique_integer([:positive])}"
    :ok = LemonCore.Bus.subscribe("user_prompts")
    :ok = UserPrompt.bind(key, self())

    {:ok, tool} =
      CodingAgent.ToolRegistry.get_tool(File.cwd!(), "ask",
        session_key: key,
        settings_manager: %{tools: %{}},
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["ask"],
        tool_policy: LemonCore.ToolPolicy.parse!(%{approval_mode: :ask}),
        approval_request_fun: fn _ -> flunk("ask must not request execution approval") end
      )

    params = %{
      "questions" => [
        %{
          "id" => "q",
          "question" => "Choose",
          "options" => [%{"label" => "A"}],
          "recommended" => 0
        }
      ]
    }

    task = Task.async(fn -> tool.execute.("first", params, nil, nil) end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key, "promptId" => id}
    }

    duplicate = tool.execute.("second", params, nil, nil)
    assert duplicate.is_error
    assert duplicate.details.error_type == "prompt_pending"

    assert :ok =
             UserPrompt.resolve(
               id,
               key,
               nil,
               %{"action" => "accept", "content" => %{"q0" => "invented"}},
               self()
             )

    result = Task.await(task)
    assert result.is_error
    assert result.details.error_type == "invalid_client_response"
    refute Map.has_key?(result.details, :results)
  end

  test "decline, timeout, cancellation and surface disconnect fail closed" do
    for outcome <- [:decline, :timeout, :cancelled, :client_down] do
      key = "native-ask-#{outcome}-#{System.unique_integer([:positive])}"
      :ok = LemonCore.Bus.subscribe("user_prompts")
      :ok = UserPrompt.bind(key, self())
      signal = LemonAgent.AbortSignal.new()

      question = %{
        "id" => "q",
        "question" => "Choose",
        "options" => [%{"label" => "recommended"}],
        "recommended" => 0
      }

      params = %{"questions" => [question]}
      params = if outcome == :timeout, do: Map.put(params, "timeout_ms", 20), else: params
      task = Task.async(fn -> Ask.execute("call", params, signal, nil, session_key: key) end)

      assert_receive %LemonCore.Event{
        type: :user_prompt_requested,
        payload: %{"sessionKey" => ^key, "promptId" => id}
      }

      case outcome do
        :decline ->
          assert :ok = UserPrompt.resolve(id, key, nil, %{"action" => "decline"}, self())

        :timeout ->
          :ok

        :cancelled ->
          LemonAgent.AbortSignal.abort(signal)

        :client_down ->
          assert :ok = UserPrompt.unbind(key, self())
      end

      result = Task.await(task)
      assert result.is_error
      refute Map.has_key?(result.details, :results)

      assert_receive %LemonCore.Event{
        type: :user_prompt_resolved,
        payload: %{"sessionKey" => ^key}
      }

      assert {:error, :not_found} =
               UserPrompt.resolve(id, key, nil, %{"action" => "accept"}, self())

      LemonAgent.AbortSignal.clear(signal)
    end
  end

  test "dead surface and dead waiter release pending questions" do
    key = "native-ask-death-#{System.unique_integer([:positive])}"
    :ok = LemonCore.Bus.subscribe("user_prompts")

    surface =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(surface)
    :ok = UserPrompt.bind(key, surface)

    task =
      Task.async(fn ->
        UserPrompt.request(key, nil, [%{"id" => "q", "question" => "Text?", "options" => []}])
      end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key, "promptId" => first_id}
    }

    send(surface, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^surface, :normal}
    assert {:error, :client_down} = Task.await(task)

    assert_receive %LemonCore.Event{
      type: :user_prompt_resolved,
      payload: %{"promptId" => ^first_id, "status" => "cancelled"}
    }

    refute UserPrompt.bound?(key)
    :ok = UserPrompt.bind(key, self())

    task =
      Task.async(fn ->
        UserPrompt.request(key, nil, [%{"id" => "q", "question" => "Text?", "options" => []}])
      end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key, "promptId" => second_id}
    }

    Task.shutdown(task, :brutal_kill)

    assert_receive %LemonCore.Event{
      type: :user_prompt_resolved,
      payload: %{"promptId" => ^second_id, "status" => "cancelled"}
    }
  end

  test "channel surface caps infinite and oversized deadlines and preserves one pending prompt" do
    key = "channel-ask-#{System.unique_integer([:positive])}"
    :ok = LemonCore.Bus.subscribe("user_prompts")
    :ok = UserPrompt.bind(key, self(), max_timeout_ms: 50)
    task = Task.async(fn -> UserPrompt.request(key, "run", [], timeout_ms: 10_000) end)

    assert_receive %LemonCore.Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key} = pending
    }

    assert pending["expiresAtMs"] - pending["requestedAtMs"] == 50
    assert {:error, :prompt_pending} = UserPrompt.request(key, "run", [])
    assert {:error, :timeout} = Task.await(task)

    assert {:error, :not_found} =
             UserPrompt.resolve(pending["promptId"], key, "run", %{"action" => "accept"}, self())

    assert :ok = UserPrompt.unbind(key, self())
    refute UserPrompt.bound?(key)
  end

  describe "html forms" do
    @form ~s(<form><fieldset><legend>Database</legend>
      <label><input type="radio" name="db" value="sqlite" checked> SQLite</label>
      <label><input type="radio" name="db" value="pg"> Postgres</label></fieldset>
      <p>Replicas</p><input type="number" name="replicas" value="2"></form>)

    test "html xor questions" do
      key = "html-xor-#{System.unique_integer([:positive])}"
      :ok = UserPrompt.bind(key, self(), html_forms: true)
      questions = [%{"id" => "q", "question" => "Choose", "options" => []}]
      opts = [session_key: key]

      both = Ask.execute("call", %{"html" => @form, "questions" => questions}, nil, nil, opts)
      assert both.is_error
      assert both.details.error_type == "invalid_arguments"
      assert hd(both.content).text =~ "not both"

      neither = Ask.execute("call", %{}, nil, nil, opts)
      assert neither.is_error
      assert neither.details.error_type == "invalid_arguments"
    end

    test "html is bounded and must be a form with answerable, non-secret fields" do
      key = "html-bounds-#{System.unique_integer([:positive])}"
      :ok = UserPrompt.bind(key, self(), html_forms: true)
      opts = [session_key: key]

      oversized = "<form><input name=\"a\">" <> String.duplicate("x", 70_000) <> "</form>"

      for html <- [
            oversized,
            "   ",
            "<p>no form</p>",
            "<form><p>no fields</p><input type=\"hidden\" name=\"h\"></form>",
            "<form><input type=\"password\" name=\"pw\"></form>",
            42
          ] do
        result = Ask.execute("call", %{"html" => html}, nil, nil, opts)
        assert result.is_error, "expected rejection of #{inspect(html, limit: 40)}"
        assert result.details.error_type == "invalid_arguments"
      end
    end

    test "surfaces that cannot render forms fail clearly instead of hanging", %{opts: acp_opts} do
      # ACP elicitation has no form-html mode.
      result = Ask.execute("call", %{"html" => @form}, nil, nil, acp_opts)
      assert result.is_error
      assert result.details.error_type == "unsupported_surface"

      # A prompt surface that did not declare html_forms (chat channels) is refused up front.
      key = "html-unsupported-#{System.unique_integer([:positive])}"
      :ok = UserPrompt.bind(key, self())
      refute UserPrompt.html_forms?(key)
      result = Ask.execute("call", %{"html" => @form}, nil, nil, session_key: key)
      assert result.is_error
      assert result.details.error_type == "unsupported_surface"
      assert {:error, :html_unsupported} = UserPrompt.request(key, nil, [], html: @form)
    end

    test "a form-capable surface receives html and its answers become readable lines plus JSON" do
      key = "html-ok-#{System.unique_integer([:positive])}"
      :ok = LemonCore.Bus.subscribe("user_prompts")
      :ok = UserPrompt.bind(key, self(), html_forms: true)
      assert UserPrompt.html_forms?(key)

      task =
        Task.async(fn ->
          Ask.execute("call", %{"html" => @form}, nil, nil, session_key: key, run_id: "run")
        end)

      assert_receive %LemonCore.Event{
        type: :user_prompt_requested,
        payload: %{"sessionKey" => ^key, "promptId" => id} = pending
      }

      assert pending["html"] == @form
      assert pending["questions"] == []

      response = %{
        "action" => "accept",
        "content" => %{"db" => "pg", "replicas" => 3},
        "answers" => [
          %{"name" => "db", "question" => "Database", "answer" => "Postgres"},
          %{"name" => "replicas", "question" => "Replicas", "answer" => "3"}
        ],
        "notes" => [
          %{
            "name" => "db",
            "question" => "Database",
            "option" => "Postgres",
            "value" => "pg",
            "text" => "managed"
          }
        ]
      }

      assert :ok = UserPrompt.resolve(id, key, "run", response, self())
      result = Task.await(task)
      refute result.is_error
      text = hd(result.content).text
      assert text =~ "Database: Postgres"
      assert text =~ "Replicas: 3"
      assert text =~ "Database / Postgres: managed"
      assert text =~ ~s(Raw form data: {"db":"pg","replicas":3})
      assert result.details.status == "answered"
      assert result.details.data == %{"db" => "pg", "replicas" => 3}
      assert [%{"name" => "db"} | _] = result.details.answers
    end

    test "answers fall back to name/value lines and malformed submissions are rejected" do
      key = "html-fallback-#{System.unique_integer([:positive])}"
      :ok = LemonCore.Bus.subscribe("user_prompts")
      :ok = UserPrompt.bind(key, self(), html_forms: true)

      ask = fn response ->
        task =
          Task.async(fn -> Ask.execute("call", %{"html" => @form}, nil, nil, session_key: key) end)

        assert_receive %LemonCore.Event{
          type: :user_prompt_requested,
          payload: %{"sessionKey" => ^key, "promptId" => id}
        }

        assert :ok = UserPrompt.resolve(id, key, nil, response, self())
        Task.await(task)
      end

      ok = ask.(%{"action" => "accept", "content" => %{"db" => "sqlite", "tags" => ["a", "b"]}})
      refute ok.is_error
      assert hd(ok.content).text =~ "db: sqlite"
      assert hd(ok.content).text =~ "tags: a, b"

      bad = ask.(%{"action" => "accept", "content" => %{"db" => %{"nested" => 1}}})
      assert bad.is_error
      assert bad.details.error_type == "invalid_client_response"

      declined = ask.(%{"action" => "decline"})
      assert declined.is_error
      assert declined.details.status == "declined"
    end
  end
end
