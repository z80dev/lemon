defmodule LemonControlPlane.Methods.SessionsPromptTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.UserPrompt
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.EventBridge
  alias LemonControlPlane.Methods.{Registry, SessionsPromptBind, SessionsPromptResolve}
  alias LemonControlPlane.Protocol.{Frames, Schemas}
  alias LemonCore.{AgentRuntime, Bus, Event}

  setup do
    previous = AgentRuntime.provider()
    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)

    on_exit(fn ->
      if previous,
        do: AgentRuntime.register(previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    unless Process.whereis(UserPrompt), do: start_supervised!(UserPrompt)
    :ok = Bus.subscribe("user_prompts")
    key = "prompt-rpc-#{System.unique_integer([:positive])}"

    {:ok,
     key: key,
     ctx: %{
       conn_id: key,
       conn_pid: self(),
       auth: %{role: :operator, scopes: [:write], token: nil, client_id: nil, identity: nil}
     }}
  end

  test "bind and resolve require write authority and a live connection", %{key: key, ctx: ctx} do
    params = %{"sessionKey" => key, "promptId" => "pending", "action" => "decline"}

    for name <- ["sessions.prompt.bind", "sessions.prompt.resolve"] do
      assert Authorize.required_scopes(name) == [:write]
      assert {:ok, _} = Registry.lookup(name)

      assert {:error, {:forbidden, _}} =
               Registry.dispatch(name, params, put_in(ctx.auth.scopes, [:read]))

      assert {:error, {:forbidden, _}} =
               Registry.dispatch(name, params, %{
                 ctx
                 | auth: %{role: :node, scopes: [:invoke, :event]}
               })
    end

    assert {:error, {:invalid_request, _, nil}} =
             SessionsPromptBind.handle(%{"sessionKey" => key}, %{})

    assert {:ok, %{"bound" => true}} =
             Registry.dispatch("sessions.prompt.bind", %{"sessionKey" => key}, ctx)

    assert UserPrompt.bound?(key)

    assert {:ok, %{"bound" => false}} =
             Registry.dispatch(
               "sessions.prompt.bind",
               %{"sessionKey" => key, "enabled" => false},
               ctx
             )

    refute UserPrompt.bound?(key)
  end

  test "question travels through event projection and exact-identity resolve wakes the waiter once",
       %{key: key, ctx: ctx} do
    assert {:ok, _} = SessionsPromptBind.handle(%{"sessionKey" => key}, ctx)
    questions = [%{"id" => "q", "question" => "Choose", "options" => [%{"label" => "A"}]}]
    task = Task.async(fn -> UserPrompt.request(key, "run", questions) end)

    assert_receive %Event{
                     type: :user_prompt_requested,
                     payload: %{"sessionKey" => ^key, "promptId" => id}
                   } = event

    assert {"session.prompt.requested", wire} = EventBridge.project(event)
    assert wire["questions"] == questions
    assert wire["runId"] == "run"
    assert "session.prompt.requested" in Frames.supported_events()
    assert :ok = Schemas.validate_event("session.prompt.requested", wire)

    params = %{
      "promptId" => id,
      "sessionKey" => key,
      "runId" => "run",
      "action" => "accept",
      "content" => %{"q0" => "A"}
    }

    assert :ok = Schemas.validate("sessions.prompt.resolve", params)

    assert {:error, {:conflict, _, nil}} =
             SessionsPromptResolve.handle(Map.put(params, "sessionKey", "foreign"), ctx)

    assert {:error, {:conflict, _, nil}} =
             SessionsPromptResolve.handle(Map.put(params, "runId", "foreign"), ctx)

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:error, {:conflict, _, nil}} =
             SessionsPromptResolve.handle(params, %{ctx | conn_pid: other})

    send(other, :stop)

    assert {:ok, %{"resolved" => true, "promptId" => ^id}} =
             Registry.dispatch("sessions.prompt.resolve", params, ctx)

    assert {:ok, %{"action" => "accept", "content" => %{"q0" => "A"}}} = Task.await(task)
    assert_receive %Event{type: :user_prompt_resolved, payload: %{"promptId" => ^id}} = resolved
    assert {"session.prompt.resolved", resolution} = EventBridge.project(resolved)
    assert resolution["status"] == "accept"
    refute Map.has_key?(resolution, "content")
    refute Map.has_key?(resolution, "questions")
    assert :ok = Schemas.validate_event("session.prompt.resolved", resolution)
    assert {:error, {:not_found, _, nil}} = SessionsPromptResolve.handle(params, ctx)
  end

  test "invalid actions and oversized content do not consume a question; decline returns no choice",
       %{key: key, ctx: ctx} do
    {:ok, _} = SessionsPromptBind.handle(%{"sessionKey" => key}, ctx)

    task =
      Task.async(fn ->
        UserPrompt.request(key, nil, [%{"id" => "q", "question" => "Text?", "options" => []}])
      end)

    assert_receive %Event{
      type: :user_prompt_requested,
      payload: %{"sessionKey" => ^key, "promptId" => id}
    }

    base = %{"promptId" => id, "sessionKey" => key, "action" => "accept", "content" => %{}}

    assert {:error, {:invalid_request, _, nil}} =
             SessionsPromptResolve.handle(Map.put(base, "action", "approve_global"), ctx)

    assert {:error, {:invalid_request, _, nil}} =
             SessionsPromptResolve.handle(
               Map.put(base, "content", %{"q0__other" => String.duplicate("x", 4001)}),
               ctx
             )

    assert {:ok, %{"resolved" => true}} =
             SessionsPromptResolve.handle(%{base | "action" => "decline"}, ctx)

    assert {:ok, %{"action" => "decline", "content" => %{}}} = Task.await(task)
  end
end
