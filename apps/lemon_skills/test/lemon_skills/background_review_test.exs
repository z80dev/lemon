defmodule LemonSkills.BackgroundReviewTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{BackgroundReview, Config, LearningNudge}
  alias LemonAi.Types.{AssistantMessage, Model, TextContent}

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    target = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    server =
      start_supervised!(
        {LearningNudge,
         name: nil,
         task_supervisor: supervisor,
         review_fun: fn request, config, digest ->
           send(target, {:review, self(), request, config, digest})
           receive do: (:finish -> :ok)
         end}
      )

    session = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(session, :stop) end)

    request = %{
      session_scope: :main,
      session_pid: session,
      user_turn: true,
      session_key: "agent:review-test:main",
      agent_id: "review-test",
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      invocation_context_key: "invocation-a",
      memory_context_key: "owner-a",
      memory_context_verified: true,
      shared_memory_grant: true
    }

    %{server: server, request: request}
  end

  test "off by default submits nothing and never evaluates a digest", ctx do
    configure(ctx, %{})

    for _ <- 1..10 do
      turn(ctx)
      finish(ctx, fn -> flunk("disabled review read a digest") end)
    end

    refute_receive {:review, _, _, _, _}
  end

  test "enabled completion submits once, replaces reminder and bounds redacted digest", ctx do
    configure(ctx, %{
      "background_review" => %{"enabled" => true, "max_digest_bytes" => 256},
      "memory_turn_interval" => 1
    })

    assert turn(ctx) == :skip

    finish(ctx, fn ->
      {"api_key=sk-abcdefghijklmnopqrstuvwxyz123456 " <> String.duplicate("x", 2000), "done"}
    end)

    assert_receive {:review, worker, request, _, digest}
    assert request.memory_context_key == "owner-a"
    assert byte_size(digest) <= 256
    assert digest =~ "UNTRUSTED DATA"
    refute digest =~ "sk-abcdefghijklmnopqrstuvwxyz123456"
    turn(ctx)
    finish(ctx)
    refute_receive {:review, _, _, _, _}
    send(worker, :finish)
  end

  test "rate limit survives worker completion", ctx do
    configure(ctx, %{"background_review" => %{"enabled" => true}, "memory_turn_interval" => 1})
    turn(ctx)
    finish(ctx)
    assert_receive {:review, worker, _, _, _}
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    turn(ctx)
    finish(ctx)
    refute_receive {:review, _, _, _, _}
  end

  test "tool threshold fires at completion, not the following prompt", ctx do
    configure(ctx, %{"background_review" => %{"enabled" => true}, "skill_tool_threshold" => 1})
    turn(ctx)
    event(ctx, :tool_dispatched, %{tool_name: "read"})
    finish(ctx)
    assert_receive {:review, worker, _, _, _}
    send(worker, :finish)
  end

  test "subagents, review, cron and unverified contexts cannot trigger", ctx do
    configure(ctx, %{"background_review" => %{"enabled" => true}, "memory_turn_interval" => 1})

    for request <- [
          %{ctx.request | session_scope: :subagent},
          %{ctx.request | session_key: "learning-review:test"},
          %{ctx.request | session_key: "agent:review-test:main:sub:cron-123"},
          %{ctx.request | memory_context_verified: false}
        ] do
      subctx = %{ctx | request: request}
      turn(subctx)
      finish(subctx)
    end

    refute_receive {:review, _, _, _, _}
  end

  test "internal followup completion cannot consume a due trigger", ctx do
    configure(ctx, %{"background_review" => %{"enabled" => true}, "memory_turn_interval" => 1})
    turn(ctx)
    turn(%{ctx | request: %{ctx.request | user_turn: false}})
    finish(ctx)
    refute_receive {:review, _, _, _, _}
    turn(ctx)
    finish(ctx)
    assert_receive {:review, worker, _, _, _}
    send(worker, :finish)
  end

  test "tool instances deny destructive skill actions and project memory; create stays draft",
       ctx do
    [remember, skill] = BackgroundReview.tools(ctx.request)
    assert remember.name == "remember"
    assert skill.name == "skill_manage"

    assert {:error, _} =
             remember.execute.("1", %{"target" => "project", "text" => "fact"}, nil, nil)

    for action <- ["delete", "unpin", "edit", "write_file", "restore"] do
      assert {:error, _} = skill.execute.("1", %{"action" => action}, nil, nil)
    end

    assert {:error, _} =
             skill.execute.(
               "1",
               %{"action" => "create", "name" => "../escape", "content" => "body"},
               nil,
               nil
             )

    assert %LemonAgent.Types.AgentToolResult{} =
             skill.execute.(
               "1",
               %{
                 "action" => "create",
                 "name" => "review-draft",
                 "content" => "---\nname: review-draft\ndescription: Test draft\n---\nProcedure"
               },
               nil,
               nil
             )

    assert {:ok, _} =
             LemonSkills.Synthesis.DraftStore.get("review-draft",
               global: false,
               cwd: ctx.request.cwd
             )

    refute File.exists?(
             Path.join([ctx.request.cwd, ".lemon", "skill", "review-draft", "SKILL.md"])
           )
  end

  test "real agent execution has only digest and two tools, no parent history or channel delivery",
       ctx do
    target = self()

    model = %Model{
      id: "mock-review",
      provider: :mock,
      api: :mock,
      context_window: 4096,
      max_tokens: 512
    }

    request =
      Map.put(ctx.request, :learning_review_options, fn override ->
        send(target, {:model_override, override})
        {:ok, [model: model]}
      end)

    stream = fn selected, context, _ ->
      send(target, {:isolated_context, selected, context})

      response = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{text: "No durable learning"}],
        stop_reason: :stop,
        provider: :mock,
        model: "mock-review"
      }

      {:ok, events} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(events, {:done, :stop, response})
      LemonAi.EventStream.complete(events, response)
      {:ok, events}
    end

    assert :ok =
             BackgroundReview.run(request, %{"model" => "cheap:mock"}, "bounded digest",
               stream_fn: stream
             )

    assert_receive {:model_override, "cheap:mock"}
    assert_receive {:isolated_context, ^model, context}
    assert Enum.map(context.tools, & &1.name) == ["remember", "skill_manage"]
    assert length(context.messages) == 1
    assert hd(context.messages).content == "bounded digest"
    assert context.system_prompt =~ "UNTRUSTED DATA"
    refute_receive {:agent_event, _}
    refute_receive {:review, _, _, _, _}
  end

  test "remember inherits the private owner but never the parent's shared grant", ctx do
    File.mkdir_p!(ctx.request.workspace_dir)
    [remember, _] = BackgroundReview.tools(ctx.request)

    result =
      remember.execute.("private", %{"text" => "Prefers concise review summaries"}, nil, nil)

    assert %LemonAgent.Types.AgentToolResult{trust: :untrusted} = result
    assert hd(result.content).text =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert {:ok, ["Prefers concise review summaries"]} = LemonMemory.Preferences.read(ctx.request)
    assert {:ok, []} = LemonMemory.Preferences.read_shared(ctx.request)

    assert {:ok, []} =
             LemonMemory.Preferences.read(%{ctx.request | memory_context_key: "other-owner"})
  end

  test "review timeout cancels a stalled provider without waiting for its response", ctx do
    target = self()
    model = %Model{id: "mock", provider: :mock, api: :mock}
    request = Map.put(ctx.request, :learning_review_options, fn _ -> {:ok, [model: model]} end)

    stream = fn _, _, _ ->
      send(target, {:stalled_provider, self()})
      receive do: (:release -> {:error, :released})
    end

    assert {:error, :timeout} =
             BackgroundReview.run(request, %{"timeout_ms" => 20}, "digest", stream_fn: stream)

    assert_receive {:stalled_provider, provider}
    ref = Process.monitor(provider)
    assert_receive {:DOWN, ^ref, :process, ^provider, _}, 1_000
  end

  test "tool-use turns have a hard configured bound", ctx do
    target = self()
    model = %Model{id: "mock", provider: :mock, api: :mock}
    request = Map.put(ctx.request, :learning_review_options, fn _ -> {:ok, [model: model]} end)

    stream = fn _, context, _ ->
      send(target, {:review_response, length(context.tools)})

      {content, reason} =
        if context.tools == [] do
          {[%TextContent{text: "Review stopped"}], :stop}
        else
          {[
             %LemonAi.Types.ToolCall{
               id: LemonCore.Id.uuid(),
               name: "skill_manage",
               arguments: %{"action" => "delete"}
             }
           ], :tool_use}
        end

      response = %AssistantMessage{
        content: content,
        stop_reason: reason,
        provider: :mock,
        model: "mock"
      }

      {:ok, events} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(events, {:done, reason, response})
      LemonAi.EventStream.complete(events, response)
      {:ok, events}
    end

    assert :ok =
             BackgroundReview.run(request, %{"max_tool_turns" => 1}, "digest", stream_fn: stream)

    assert_receive {:review_response, 2}
    refute_receive {:review_response, _}
  end

  test "review tools retain parent policy and never authorize a subagent", ctx do
    request = Map.put(ctx.request, :tool_policy, %{deny: ["remember"]})
    assert Enum.map(BackgroundReview.tools(request), & &1.name) == ["skill_manage"]
    request = Map.put(ctx.request, :tool_policy, %{require_approval: ["skill_manage"]})
    assert Enum.map(BackgroundReview.tools(request), & &1.name) == ["remember"]
    assert BackgroundReview.tools(%{ctx.request | session_scope: :subagent}) == []
  end

  test "review patches use the existing audit and cannot modify pinned skills", ctx do
    normal = LemonSkills.Tools.SkillManage.tool(cwd: ctx.request.cwd)
    content = "---\nname: protected\ndescription: Captures a workflow\n---\nProven procedure.\n"

    assert %LemonAgent.Types.AgentToolResult{} =
             normal.execute.(
               "create",
               %{"action" => "create", "name" => "protected", "content" => content},
               nil,
               nil
             )

    [_, review] = BackgroundReview.tools(ctx.request)

    params = %{
      "action" => "patch",
      "name" => "protected",
      "old_string" => "Proven procedure.",
      "new_string" => "Updated procedure."
    }

    assert %LemonAgent.Types.AgentToolResult{} = review.execute.("patch", params, nil, nil)
    normal.execute.("pin", %{"action" => "pin", "name" => "protected"}, nil, nil)

    assert {:error, error} =
             review.execute.(
               "patch-again",
               %{
                 params
                 | "old_string" => "Updated procedure.",
                   "new_string" => "Forbidden change."
               },
               nil,
               nil
             )

    assert error =~ "pinned"
  end

  defp configure(ctx, settings),
    do: Config.save_config(%{"learning_nudge" => settings}, false, ctx.request.cwd)

  defp turn(ctx), do: LearningNudge.contribute(ctx.request, server: ctx.server)

  defp event(ctx, name, extra \\ %{}) do
    LearningNudge.handle_session_event(
      [:coding_agent, :session, name],
      %{},
      Map.merge(ctx.request, extra),
      ctx.server
    )
  end

  defp finish(ctx, summary \\ fn -> {"finished task", "completed answer"} end) do
    event(ctx, :run_completed)
    LearningNudge.review_completed(ctx.request.session_pid, summary, ctx.server)
  end
end
