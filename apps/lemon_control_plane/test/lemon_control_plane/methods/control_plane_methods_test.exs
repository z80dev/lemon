defmodule LemonControlPlane.Methods.ControlPlaneMethodsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for control-plane method implementations.
  """

  defmodule CompactSessionStub do
    use GenServer

    def start_link({test_pid, session_key}) do
      GenServer.start_link(__MODULE__, {test_pid, session_key})
    end

    @impl true
    def init({test_pid, session_key}) do
      Registry.register(CodingAgent.SessionRegistry, session_key, :test)
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call({:compact, opts}, _from, state) do
      send(state.test_pid, {:compact_opts, opts})
      {:reply, :ok, state}
    end
  end

  describe "Agent" do
    alias LemonControlPlane.Methods.Agent

    test "name/0 returns correct method name" do
      assert Agent.name() == "agent"
    end

    test "scopes/0 returns write scope" do
      assert Agent.scopes() == [:write]
    end

    test "handle/2 returns idempotent submission with prompt cleanup summary" do
      key = "agent-submit-#{System.unique_integer([:positive, :monotonic])}"

      LemonCore.Idempotency.put(:agent, key, %{
        "run_id" => "run_cached",
        "session_key" => "agent:builder:main"
      })

      on_exit(fn -> LemonCore.Idempotency.delete(:agent, key) end)

      {:ok, result} =
        Agent.handle(
          %{
            "prompt" => "private prompt body",
            "agent_id" => "builder",
            "queue_mode" => "steer",
            "model" => "openai:gpt-4.1",
            "idempotency_key" => key
          },
          %{}
        )

      assert result["run_id"] == "run_cached"
      assert result["summary"]["agentId"] == "builder"
      assert result["summary"]["sessionKey"] == "agent:builder:main"
      assert result["summary"]["runId"] == "run_cached"
      assert result["summary"]["queueMode"] == "steer"
      assert result["summary"]["promptBytes"] == byte_size("private prompt body")
      assert result["summary"]["hasModelOverride"] == true
      assert result["summary"]["hasIdempotencyKey"] == true
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private prompt body"
    end
  end

  describe "AgentWait" do
    alias LemonControlPlane.Methods.AgentWait

    test "name/0 returns correct method name" do
      assert AgentWait.name() == "agent.wait"
    end

    test "scopes/0 returns read scope" do
      assert AgentWait.scopes() == [:read]
    end

    test "handle/2 returns completed run with bounded answer summary" do
      run_id = "run_wait_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:main:#{System.unique_integer([:positive])}"

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{run_id: run_id, ok: true, answer: "private answer body"},
        prompt: "private prompt body",
        session_key: session_key
      })

      {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})

      assert result["runId"] == run_id
      assert result["ok"] == true
      assert result["answer"] == "private answer body"
      assert result["summary"]["runId"] == run_id
      assert result["summary"]["answerReturned"] == true
      assert result["summary"]["answerBytes"] == byte_size("private answer body")
      assert result["summary"]["hasError"] == false
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["redactsSensitiveAnswerValues"] == true
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result["summary"]) =~ "private answer body"
      refute inspect(result["summary"]) =~ "private prompt body"
    end

    test "completed cancellation proof is projected independently of error text" do
      for {proof, expected} <- [{true, true}, {false, false}, {nil, false}] do
        run_id = "run_wait_cancelled_#{System.unique_integer([:positive, :monotonic])}"
        LemonCore.RunStore.finalize(run_id, %{
          completed: %{run_id: run_id, ok: false, error: :interrupted,
                       meta: %{cancelled: proof}},
          session_key: "agent:wait:cancelled"
        })
        assert {:ok, result} =
                 AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})
        assert result["cancelled"] == expected
      end
    end

    test "status-only completion query does not transfer private answer or usage" do
      run_id = "run_wait_status_#{System.unique_integer([:positive, :monotonic])}"
      private_answer = "private cancellation-owner answer"

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{
          run_id: run_id,
          ok: false,
          answer: private_answer,
          error: :interrupted,
          usage: %{total_tokens: 731},
          meta: %{cancelled: true, budget: %{max_total_tokens: 900}}
        },
        session_key: "agent:wait:status"
      })

      assert {:ok, result} =
               AgentWait.handle(
                 %{"runId" => run_id, "timeoutMs" => 1, "includeAnswer" => false},
                 %{}
               )

      assert result["runId"] == run_id
      assert result["ok"] == false
      assert result["cancelled"] == true
      assert result["error"] == ":interrupted"
      assert result["answer"] == nil
      assert result["summary"]["answerReturned"] == false
      assert result["summary"]["answerBytes"] == 0
      refute Map.has_key?(result, "usage")
      refute Map.has_key?(result, "budget")
      refute inspect(result) =~ private_answer

      assert {:ok, original_result} =
               AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})

      assert original_result["answer"] == private_answer
      assert original_result["usage"]["total_tokens"] == 731
    end

    test "status projection rejects nonboolean includeAnswer rather than returning answer" do
      for value <- [nil, "false", 0, [], %{}] do
        assert {:error, {:invalid_request, "includeAnswer must be a boolean", nil}} =
                 AgentWait.handle(%{"runId" => "foreign-private-run", "includeAnswer" => value}, %{})
      end
    end

    test "budget failure results retain machine-readable caps and actual usage for print JSON" do
      run_id = "run_wait_budget_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:budget:#{System.unique_integer([:positive])}"

      details = %{
        reason: :budget_exceeded,
        scope: :session,
        metric: :cost_usd,
        limit: 1.0,
        used: 1.25,
        run_usage: %{tokens: 30, cost_usd: 0.5},
        session_usage: %{tokens: 80, cost_usd: 1.25},
        message: "Session cost budget exceeded. Increase max_session_cost_usd to continue."
      }

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{
          run_id: run_id,
          ok: false,
          error: details.message,
          answer: "",
          usage: %{total_tokens: 30, cost: %{total: 0.5}},
          meta: %{budget: details}
        },
        session_key: session_key
      })

      on_exit(fn -> LemonCore.RunStore.delete_session(session_key) end)

      assert {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})
      json = result |> Jason.encode!() |> Jason.decode!()
      assert json["ok"] == false
      assert json["error"] == details.message
      assert json["budget"]["reason"] == "budget_exceeded"
      assert json["budget"]["scope"] == "session"
      assert json["budget"]["metric"] == "cost_usd"
      assert json["budget"]["limit"] == 1.0
      assert json["budget"]["used"] == 1.25
      assert json["usage"]["total_tokens"] == 30
      assert json["usage"]["cost"]["total"] == 0.5
    end

    test "typed usage with runtime metrics is projected before encoding the wait response" do
      run_id = "run_wait_typed_usage_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:typed-usage:#{System.unique_integer([:positive])}"

      usage =
        %LemonAi.Types.Usage{
          input: 10,
          output: 5,
          cache_write: 4,
          cache_write_long: 2,
          total_tokens: 19,
          cost: %LemonAi.Types.Cost{total: 0.5, cache_write: 0.1}
        }
        |> Map.merge(%{
          turns: 2,
          tool_errors: 1,
          context_tokens: 19,
          context_budget: %{used_tokens: 19, available_tokens: 100},
          tokens: 19,
          cost_usd: 0.5,
          private: "must not cross the wire"
        })

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{run_id: run_id, ok: false, error: "Cancelled", usage: usage},
        session_key: session_key
      })

      on_exit(fn -> LemonCore.RunStore.delete_session(session_key) end)

      assert {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})
      json = result |> Jason.encode!() |> Jason.decode!()
      assert json["usage"]["total_tokens"] == 19
      assert json["usage"]["cache_write_long"] == 2
      assert json["usage"]["cost"]["total"] == 0.5
      assert json["usage"]["cost"]["cache_write"] == 0.1
      assert json["usage"]["turns"] == 2
      assert json["usage"]["tool_errors"] == 1
      assert json["usage"]["context_tokens"] == 19
      assert is_map(json["usage"]["context_budget"])
      assert json["usage"]["tokens"] == 19
      assert json["usage"]["cost_usd"] == 0.5
      refute Map.has_key?(json["usage"], "__struct__")
      refute Map.has_key?(json["usage"], "private")
    end

    test "handle/2 redacts sensitive answer and error values" do
      run_id = "run_wait_redaction_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:redaction:#{System.unique_integer([:positive])}"
      answer_secret = "ANSWER_WAIT_TOKEN_#{System.unique_integer([:positive])}"
      error_secret = "ERROR_WAIT_BEARER_#{System.unique_integer([:positive])}"

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{
          run_id: run_id,
          ok: false,
          answer: "done token=#{answer_secret}",
          error: "failed Bearer #{error_secret}"
        },
        prompt: "private prompt body",
        session_key: session_key
      })

      {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})

      refute inspect(result) =~ answer_secret
      refute inspect(result) =~ error_secret
      assert result["ok"] == false
      assert result["summary"]["cleanup"]["redactsSensitiveAnswerValues"] == true
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end

  describe "SessionsCompact" do
    alias LemonControlPlane.Methods.SessionsCompact

    test "name/0 returns correct method name" do
      assert SessionsCompact.name() == "sessions.compact"
    end

    test "scopes/0 returns admin scope" do
      assert SessionsCompact.scopes() == [:admin]
    end

    test "handle/2 returns compact cleanup summary without custom summary text" do
      unless Process.whereis(CodingAgent.SessionRegistry) do
        start_supervised!({Registry, keys: :unique, name: CodingAgent.SessionRegistry})
      end

      session_key = "compact-session-#{System.unique_integer([:positive, :monotonic])}"
      custom_summary = "private compaction summary token=COMPACT_SECRET"

      start_supervised!({CompactSessionStub, {self(), session_key}})

      {:ok, result} =
        SessionsCompact.handle(
          %{"sessionKey" => session_key, "force" => true, "summary" => custom_summary},
          %{}
        )

      assert_received {:compact_opts, opts}
      assert Keyword.fetch!(opts, :force) == true
      assert Keyword.fetch!(opts, :summary) == custom_summary
      assert result["success"] == true
      assert result["sessionKey"] == session_key
      assert result["summary"]["sessionKeyReturned"] == true
      assert result["summary"]["compacted"] == true
      assert result["summary"]["force"] == true
      assert result["summary"]["customSummaryProvided"] == true
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesSummaryText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private compaction summary"
      refute inspect(result) =~ "COMPACT_SECRET"
    end
  end

  describe "ChatAbort" do
    alias LemonControlPlane.Methods.ChatAbort

    defmodule AbortResultRouter do
      def abort_run(_run_id, _reason), do: {:error, {:private, "/secret/path"}}
      def abort(_session_key, _reason), do: {:error, :unavailable}
    end

    defmodule AbortRaiseRouter do
      def abort_run(_run_id, _reason), do: raise("private abort failure")
      def abort(_session_key, _reason), do: exit(:private_abort_failure)
    end

    test "summarizes run-scoped abort without message payloads" do
      {:ok, result} = ChatAbort.handle(%{"runId" => "run-abort-summary"}, %{})

      assert result["runId"] == "run-abort-summary"
      assert result["summary"]["targetType"] == "run"
      assert result["summary"]["targetId"] == "run-abort-summary"
      assert result["summary"]["reason"] == "user_requested"

      assert result["summary"]["dispatchStatus"] in [
               "sent",
               "router_unavailable",
               "outcome_unknown",
               "rejected"
             ]

      assert result["aborted"] == (result["summary"]["dispatchStatus"] == "sent")
      assert result["summary"]["cleanup"]["includesPrompt"] == false
      assert result["summary"]["cleanup"]["includesMessages"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "summarizes session-scoped abort without message payloads" do
      {:ok, result} = ChatAbort.handle(%{"sessionKey" => "session-abort-summary"}, %{})

      assert result["sessionKey"] == "session-abort-summary"
      assert result["summary"]["targetType"] == "session"
      assert result["summary"]["targetId"] == "session-abort-summary"

      assert result["summary"]["dispatchStatus"] in [
               "sent",
               "router_unavailable",
               "outcome_unknown",
               "rejected"
             ]

      assert result["aborted"] == (result["summary"]["dispatchStatus"] == "sent")
      assert result["summary"]["cleanup"]["includesMessages"] == false
    end

    test "reports bounded failure statuses without leaking router terms" do
      {:ok, rejected} =
        ChatAbort.handle(%{"runId" => "run-rejected"}, %{router_mod: AbortResultRouter})

      assert rejected["aborted"] == false
      assert rejected["summary"]["dispatchStatus"] == "rejected"
      refute inspect(rejected) =~ "/secret/path"
      refute inspect(rejected) =~ "private"

      {:ok, unavailable} =
        ChatAbort.handle(%{"sessionKey" => "session-unavailable"}, %{
          router_mod: AbortResultRouter
        })

      assert unavailable["aborted"] == false
      assert unavailable["summary"]["dispatchStatus"] == "router_unavailable"
    end

    test "reports router raises and exits as outcome unknown for both target types" do
      {:ok, run_result} =
        ChatAbort.handle(%{"runId" => "run-unknown"}, %{router_mod: AbortRaiseRouter})

      {:ok, session_result} =
        ChatAbort.handle(%{"sessionKey" => "session-unknown"}, %{
          router_mod: AbortRaiseRouter
        })

      for result <- [run_result, session_result] do
        assert result["aborted"] == false
        assert result["summary"]["dispatchStatus"] == "outcome_unknown"
        refute inspect(result) =~ "private"
      end
    end
  end

  describe "ChatSend" do
    alias LemonControlPlane.Methods.ChatSend

    test "name/0 returns correct method name" do
      assert ChatSend.name() == "chat.send"
    end

    test "scopes/0 returns write scope" do
      assert ChatSend.scopes() == [:write]
    end

    test "handle/2 submits echo run with prompt cleanup summary" do
      {:ok, _} = Application.ensure_all_started(:lemon_router)

      session_key = "agent:chat-send:main:#{System.unique_integer([:positive, :monotonic])}"
      prompt = "with echo private chat prompt"

      {:ok, result} =
        ChatSend.handle(
          %{
            "sessionKey" => session_key,
            "agentId" => "default",
            "prompt" => prompt,
            "queueMode" => "steer"
          },
          %{}
        )

      assert is_binary(result["runId"])
      assert result["sessionKey"] == session_key
      assert result["summary"]["runId"] == result["runId"]
      assert result["summary"]["sessionKey"] == session_key
      assert result["summary"]["agentId"] == "default"
      assert result["summary"]["queueMode"] == "steer"
      assert result["summary"]["promptBytes"] == byte_size(prompt)
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private chat prompt"
    end

    test "preserves redirect as a distinct queue mode" do
      {:ok, _} = Application.ensure_all_started(:lemon_router)

      session_key = "agent:chat-redirect:main:#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, result} =
               ChatSend.handle(
                 %{
                   "sessionKey" => session_key,
                   "prompt" => "replace the pending direction",
                   "queueMode" => "redirect"
                 },
                 %{}
               )

      assert result["summary"]["queueMode"] == "redirect"
    end
  end

  describe "Node pairing methods" do
    alias LemonControlPlane.Methods.NodePairRequest

    test "NodePairRequest returns error when nodeName is missing" do
      {:error, _} = NodePairRequest.handle(%{"nodeType" => "browser"}, %{})
    end
  end
end
