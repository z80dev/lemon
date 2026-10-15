defmodule CodingAgent.Tools.AskTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Tools.Ask
  alias LemonCore.ACPClientBridge
  alias CodingAgent.Session.UserPrompt

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
end
