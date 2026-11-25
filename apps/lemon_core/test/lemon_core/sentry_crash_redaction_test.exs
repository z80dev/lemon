defmodule LemonCore.SentryCrashRedactionTest do
  # Mutates global Sentry config and attaches a :logger handler.
  use ExUnit.Case, async: false

  @prompt "PRIVATE-PROMPT-please-summarize-my-medical-history"
  @answer "PRIVATE-ANSWER-you-have-condition-x"

  defmodule PromptServer do
    use GenServer

    def start(state), do: GenServer.start(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:raise, text}, _state), do: raise("model failed on #{text}")
    def handle_cast({:match, text}, state), do: {:noreply, Map.put(state, :x, {:ok, _} = text)}
    def handle_cast({:exit, text}, _state), do: exit({:bad_answer, text})
  end

  defmodule RedactedPromptServer do
    use GenServer

    def start(state), do: GenServer.start(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def format_status(status),
      do: LemonCore.StatusRedaction.gen_server(status, [:run_id, :session_key])

    @impl true
    def handle_cast({:raise, text}, _state), do: raise("model failed on #{text}")
  end

  setup do
    test = self()

    {sentry_config, handler} = runtime_sentry_config()

    previous =
      for key <- [:dsn, :before_send, :after_send_event, :dedup_events] do
        {key, :persistent_term.get({:sentry_config, key}, nil)}
      end

    :ok = Sentry.put_config(:dsn, "http://public:secret@127.0.0.1:9/1")
    # Whatever runtime.exs configures (nothing, before the fix) is what is tested.
    Sentry.Config.persist(before_send: Keyword.get(sentry_config, :before_send))
    :ok = Sentry.put_config(:dedup_events, false)

    :ok =
      Sentry.put_config(:after_send_event, fn event, _result ->
        send(test, {:sentry_event, event})
      end)

    {:handler, id, module, handler_config} = handler
    handler_id = :"#{id}_t16f_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler_id, module, handler_config)

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Enum.each(previous, fn {key, value} -> Sentry.Config.persist([{key, value}]) end)
    end)

    :ok
  end

  test "config/runtime.exs installs the scrubber as Sentry before_send" do
    {sentry_config, {:handler, _id, Sentry.LoggerHandler, _}} = runtime_sentry_config()
    assert sentry_config[:before_send] == {LemonCore.SentryScrubber, :before_send}
  end

  test "a raising GenServer holding a prompt sends no prompt, answer or state" do
    pid = start_prompt_server(PromptServer)
    GenServer.cast(pid, {:raise, @prompt})

    assert_clean_event(pid)
  end

  test "a badmatch on conversation content sends no prompt" do
    pid = start_prompt_server(PromptServer)
    GenServer.cast(pid, {:match, @prompt})

    assert_clean_event(pid)
  end

  test "an exit reason carrying an answer sends no answer" do
    pid = start_prompt_server(PromptServer)
    GenServer.cast(pid, {:exit, @answer})

    assert_clean_event(pid)
  end

  test "format_status redaction keeps the exception type and ids for triage" do
    {:ok, pid} =
      RedactedPromptServer.start(%{run_id: "run_t16f", session_key: "sk_t16f", prompt: @prompt})

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:raise, @prompt})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    event = await_event()

    rendered =
      inspect(Sentry.Client.render_event(event), limit: :infinity, printable_limit: :infinity)

    refute rendered =~ "PRIVATE-"
    assert [%{type: type}] = event.exception
    assert type == "LemonCore.StatusRedaction.RedactedCrashError"
  end

  test "scrubber drops call payload fingerprints, frame vars, breadcrumbs and request bodies" do
    event = %Sentry.Event{
      event_id: "0",
      timestamp: "now",
      message: %Sentry.Interfaces.Message{
        message: "exited in: GenServer.call(pid, {:prompt, \"#{@prompt}\"}, 5000)",
        formatted: "exited in: GenServer.call(pid, {:prompt, \"#{@prompt}\"}, 5000)"
      },
      fingerprint: ["timeout", "genserver_call", "{:prompt, \"#{@prompt}\"}"],
      breadcrumbs: [%Sentry.Interfaces.Breadcrumb{message: @prompt}],
      extra: %{genserver_state: @prompt, logger_metadata: %{file: "x.ex", line: 1, text: @prompt}},
      request: %Sentry.Interfaces.Request{data: @prompt, cookies: %{"c" => @prompt}},
      exception: [
        %Sentry.Interfaces.Exception{
          type: "FunctionClauseError",
          value: @prompt,
          stacktrace: %Sentry.Interfaces.Stacktrace{
            frames: [
              %Sentry.Interfaces.Stacktrace.Frame{function: "f/1", vars: %{"arg0" => @prompt}}
            ]
          }
        }
      ]
    }

    scrubbed = LemonCore.SentryScrubber.before_send(event)

    refute inspect(scrubbed, limit: :infinity, printable_limit: :infinity) =~ "PRIVATE-"
    assert scrubbed.fingerprint == ["timeout", "genserver_call"]
    assert scrubbed.extra == %{logger_metadata: %{file: "x.ex", line: 1}}
    assert [%{type: "FunctionClauseError", value: "[redacted]"}] = scrubbed.exception
  end

  defp start_prompt_server(module) do
    {:ok, pid} =
      module.start(%{
        run_id: "run_t16f",
        session_key: "sk_t16f",
        prompt: @prompt,
        messages: [%{role: :user, content: @prompt}, %{role: :assistant, content: @answer}]
      })

    pid
  end

  defp assert_clean_event(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    event = await_event()

    rendered =
      inspect(Sentry.Client.render_event(event), limit: :infinity, printable_limit: :infinity)

    refute rendered =~ "PRIVATE-"
    refute Map.has_key?(event.extra, :genserver_state)
    refute Map.has_key?(event.extra, :last_message)
    refute Map.has_key?(event.extra, :crash_reason)
  end

  defp await_event do
    assert_receive {:sentry_event, event}, 5_000
    event
  end

  # Evaluates the real config/runtime.exs as a release would with SENTRY_DSN set.
  defp runtime_sentry_config do
    previous = System.get_env("SENTRY_DSN")
    System.put_env("SENTRY_DSN", "http://public:secret@127.0.0.1:9/1")

    try do
      config =
        Config.Reader.read!(Path.expand("../../../../config/runtime.exs", __DIR__),
          env: :prod,
          target: :host
        )

      [handler] = get_in(config, [:lemon_core, :logger])
      {Keyword.fetch!(config, :sentry), handler}
    after
      if previous,
        do: System.put_env("SENTRY_DSN", previous),
        else: System.delete_env("SENTRY_DSN")
    end
  end
end
