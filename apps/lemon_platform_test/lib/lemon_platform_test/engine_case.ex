defmodule LemonPlatformTest.EngineCase do
  @moduledoc """
  Compliance suite for `LemonGateway.Engine` implementations.

  ## What an engine is

  An engine is the thing that actually answers. `LemonGateway` decides *that* a
  run should happen — concurrency, locking, scheduling, resume — and hands the
  work to an engine, which wraps a CLI tool (`codex`, `claude`, `droid`), an API,
  or an in-process agent. `LemonGateway.Engines.Echo` is the reference
  implementation and is 60 lines long; `CodingAgent.GatewayEngine` is a real one
  that lives in a different application entirely and registers itself at boot.

  Engines do not return answers. They start work and stream events to a sink
  process, which is what makes a run observable while it is still running.

  ## The contract

  ### Identity

  `id/0` returns a slug matching `~r/^[a-z][a-z0-9_-]*$/` that is not `"default"`
  or `"help"` — `LemonGateway.EngineRegistry` reserves those two and refuses to
  start with an engine that claims either. The id appears in resume tokens,
  routing config and user-visible commands, so treat it as permanent.

  ### Resume tokens round-trip

  Three callbacks share one job: letting a later run continue an earlier
  session.

    * `format_resume/1` renders a `LemonCore.ResumeToken` as the literal command
      a user could paste (`"codex resume thread_abc"`, `"claude --resume xyz"`).
    * `extract_resume/1` finds your token in arbitrary text — typically the tail
      of your own tool's output — and returns a `%LemonCore.ResumeToken{}` or
      `nil`. It must return `nil`, never raise, for text that is not yours, and
      it must not claim another engine's tokens.
    * `is_resume_line/1` answers whether a line is *only* a resume command, so
      renderers can keep it when truncating output.

  The suite checks the cycle: a token you formatted must be extractable, must
  come back with your `id/0` and the same value, and must be recognised as a
  resume line.

  ### Runs are asynchronous and event-driven

  `start_run/3` returns `{:ok, run_ref, cancel_ctx}` *immediately* — before the
  work finishes — or `{:error, reason}`. Everything the caller learns after that
  arrives as messages to `sink_pid`:

      {:engine_event, run_ref, event}   # LemonGateway.Event.started/action_event/completed
      {:engine_delta, run_ref, text}    # streaming text

  `run_ref` ties messages to the run; `cancel_ctx` is opaque state you will be
  handed back. Emit exactly one `started` event and, eventually, exactly one
  `completed` event — the gateway's run lifecycle hangs on the completed event
  arriving even for failures (`ok: false`), so an engine that dies silently
  leaves a run wedged until the watchdog fires.

  ### `cancel/1` is total

  The gateway calls `cancel(cancel_ctx)` and expects `:ok` — for the exact term
  your `start_run/3` returned, for a stale or partial one it is holding after a
  crash or restart, and for a run that already finished. Cancelling twice is
  `:ok` too. Pattern-matching only your happy-path context turns a routine
  cancellation into a `FunctionClauseError` in the caller, so end your clauses
  with `def cancel(_ctx), do: :ok`.

  ### Steering is optional but must be declared honestly

  `supports_steer?/0` is a required callback; `steer/2` is optional. If you
  answer `true` you must export `steer/2` and accept mid-run text, returning
  `:ok` or `{:error, reason}`.

  ## Minimal implementation

      defmodule MyApp.Engine do
        @behaviour LemonGateway.Engine

        alias LemonCore.ResumeToken
        alias LemonGateway.Event

        @impl true
        def id, do: "myengine"

        @impl true
        def format_resume(%ResumeToken{value: value}), do: "myengine resume \#{value}"

        @impl true
        def extract_resume(text) do
          case Regex.run(~r/myengine\\s+resume\\s+([\\w-]+)/i, text) do
            [_, value] -> %ResumeToken{engine: id(), value: value}
            _ -> nil
          end
        end

        @impl true
        def is_resume_line(line), do: Regex.match?(~r/^\\s*myengine\\s+resume\\s+[\\w-]+\\s*$/i, line)

        @impl true
        def supports_steer?, do: false

        @impl true
        def start_run(job, _opts, sink_pid) do
          run_ref = make_ref()
          resume = job.resume || %ResumeToken{engine: id(), value: "session-1"}

          {:ok, pid} =
            Task.start(fn ->
              send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
              answer = MyApp.Api.complete(job.prompt)

              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
            end)

          {:ok, run_ref, %{task_pid: pid}}
        end

        @impl true
        def cancel(%{task_pid: pid}) when is_pid(pid) do
          Process.exit(pid, :kill)
          :ok
        end

        def cancel(_ctx), do: :ok
      end

  ## Registering from another application

  An engine that ships outside `lemon_gateway` registers itself when its own
  application starts:

      LemonGateway.EngineRegistry.register(MyApp.Engine)

  Registration is idempotent, validates the id, and survives a registry restart.
  This suite performs that round-trip (see the `:registry` option).

  ## Running the suite

      defmodule MyApp.EngineComplianceTest do
        use LemonPlatformTest.EngineCase, async: false, engine: MyApp.Engine
      end

  By default this runs the *static* contract only: identity, resume-token
  cycle, callback consistency, registry round-trip. Nothing is executed. Pass a
  `:run_probe` to also exercise the run lifecycle, which is worth doing for any
  engine that can answer without a network call or a real model:

      defmodule MyApp.EngineComplianceTest do
        use LemonPlatformTest.EngineCase,
          async: false,
          engine: MyApp.Engine,
          run_probe: {__MODULE__, :job}

        def job(_context) do
          %LemonGateway.Types.Job{run_id: "compliance", prompt: "ping", engine_id: "myengine"}
        end
      end

  ## Options

    * `:engine` — required, the engine module under test.
    * `:resume_value` — the token value used for the round-trip. Default
      `"session-abc123"`. Must be something your `extract_resume/1` accepts;
      keep it to `[A-Za-z0-9_-]`.
    * `:registry` — round-trip the engine through `LemonGateway.EngineRegistry`.
      Default `true`, because "works standalone, invisible to the platform" is
      the integration failure this suite exists to catch. It is also the only
      option that is on by default and touches global state, so it is worth
      knowing exactly what it does: it starts `:lemon_gateway` if nothing else
      has (with the health listener disabled, so no port is bound), and
      `LemonGateway.Application.start/2` in turn points
      `LemonCore.EngineInfoBridge` at the gateway's registries for the rest of
      the VM's life. The engine list it registers into is snapshotted and
      restored per test. Pass `registry: false` in a suite where starting the
      gateway is not acceptable.
    * `:run_probe` — `{Module, :function}` returning a `%LemonGateway.Types.Job{}`,
      called with the test context. Enables the lifecycle tests: `start_run/3`
      returns a ref, a `started` event arrives at the sink, and `cancel/1`
      returns `:ok`. Only pass this if running the job is free and offline.
    * `:run_timeout` — milliseconds to wait for the `started` event. Default
      `2_000`.
    * `:cancel_tolerates_unknown_ctx` — assert that `cancel/1` returns `:ok`
      for a context it did not produce. Default `true`, because
      `c:LemonGateway.Engine.cancel/1` requires it. Set it to `false` only to
      quarantine a known-strict engine you have not fixed yet; that is a
      departure from the contract, not a supported configuration.

  ## Known gaps in the behaviour

    * **`steer/2` is optional but `supports_steer?/0` is not.** An engine that
      answers `false` still has to define `supports_steer?/0`; nothing stops an
      engine from answering `true` and omitting `steer/2` except this suite,
      because making `steer/2` mandatory would break every engine that does not
      steer.
    * **`start_run/3`'s `opts` are a loose map.** `run_opts()` documents `:cwd`,
      `:env`, `:timeout_ms` and `:capabilities` as optional keys, and engines
      differ on which they honour. The suite passes `%{}` and does not assert
      how options are interpreted.
  """

  use ExUnit.CaseTemplate

  @reserved_ids ~w(default help)

  @doc """
  Engine ids `LemonGateway.EngineRegistry` refuses to register.
  """
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @doc """
  Text `extract_resume/1` is probed with, none of which it may raise on.

  Chat text is arbitrary user input and the registry calls every engine's
  `extract_resume/1` on it in turn, inside its own process. The list mixes the
  shapes that break naive regex and slicing code — truncated resume lines, the
  engine's own id with nothing after it, unbalanced backticks, newlines,
  non-ASCII, and something long enough to matter.
  """
  @spec hostile_resume_text(String.t()) :: [String.t()]
  def hostile_resume_text(engine_id) when is_binary(engine_id) do
    [
      "",
      " ",
      "\n",
      "\n\n\n",
      "`",
      "```",
      engine_id,
      "#{engine_id} resume",
      "#{engine_id} resume ",
      "#{engine_id} resume\n",
      "`#{engine_id} resume`",
      "#{engine_id}  resume  #{engine_id}  resume  x",
      "resume #{engine_id}",
      "--resume",
      "#{engine_id} resume ../../etc/passwd",
      "#{engine_id} resume \0nul",
      "🍋 #{engine_id} resume 🍋",
      "上下文 #{engine_id} resume 值",
      String.duplicate("a", 10_000),
      String.duplicate("#{engine_id} resume x\n", 200)
    ]
  end

  using opts do
    engine = Keyword.fetch!(opts, :engine)
    resume_value = Keyword.get(opts, :resume_value, "session-abc123")
    registry? = Keyword.get(opts, :registry, true)
    run_probe = Keyword.get(opts, :run_probe)
    run_timeout = Keyword.get(opts, :run_timeout, 2_000)
    unknown_ctx? = Keyword.get(opts, :cancel_tolerates_unknown_ctx, true)
    label = Macro.to_string(engine)

    quote do
      @engine unquote(engine)
      @resume_value unquote(resume_value)
      @run_probe unquote(run_probe)
      @run_timeout unquote(run_timeout)

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonGateway.Engine" do
          assert LemonPlatformTest.declares_behaviour?(@engine, LemonGateway.Engine),
                 "#{inspect(@engine)} must declare `@behaviour LemonGateway.Engine`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@engine, LemonGateway.Engine) == []
        end
      end

      describe unquote(label <> " id/0") do
        test "is a stable slug the engine registry accepts" do
          id = @engine.id()

          assert is_binary(id), "id/0 must return a binary, got: #{inspect(id)}"

          assert Regex.match?(~r/^[a-z][a-z0-9_-]*$/, id),
                 "engine id #{inspect(id)} must match ~r/^[a-z][a-z0-9_-]*$/"

          refute id in LemonPlatformTest.EngineCase.reserved_ids(),
                 "engine id #{inspect(id)} is reserved by LemonGateway.EngineRegistry"

          assert @engine.id() == id, "id/0 must return the same value on every call"
        end
      end

      describe unquote(label <> " resume tokens") do
        test "format_resume/1 renders the token value" do
          rendered = @engine.format_resume(lemon_engine_token())

          assert is_binary(rendered), "format_resume/1 must return a binary"

          assert String.contains?(rendered, @resume_value),
                 "format_resume/1 must include the token value, got: #{inspect(rendered)}"

          refute String.contains?(rendered, "\n"),
                 "format_resume/1 must render a single line, got: #{inspect(rendered)}"
        end

        test "extract_resume/1 recovers what format_resume/1 rendered" do
          rendered = @engine.format_resume(lemon_engine_token())

          assert %LemonCore.ResumeToken{} = token = @engine.extract_resume(rendered),
                 "extract_resume/1 did not recognise its own format_resume/1 output: #{inspect(rendered)}"

          assert token.engine == @engine.id(),
                 "the extracted token must carry this engine's id, got #{inspect(token.engine)}"

          assert token.value == @resume_value
        end

        test "extract_resume/1 returns nil for text it does not own" do
          assert @engine.extract_resume("") == nil
          assert @engine.extract_resume("just a sentence with no resume command") == nil

          # A line that merely embeds this engine's id inside a longer word
          # belongs to some other tool, not to this engine.
          assert @engine.extract_resume("not#{@engine.id()}x resume #{@resume_value}") == nil,
                 "extract_resume/1 must not claim another engine's resume line"
        end

        test "extract_resume/1 does not raise on hostile text" do
          for text <- LemonPlatformTest.EngineCase.hostile_resume_text(@engine.id()) do
            result =
              try do
                @engine.extract_resume(text)
              rescue
                error ->
                  flunk("""
                  extract_resume/1 raised on #{inspect(text)}:

                    #{Exception.format(:error, error, __STACKTRACE__)}

                  Engines are called from inside LemonGateway.EngineRegistry's own
                  process, on the path every inbound message takes. A raise here
                  takes the registry down, and enough of them take the gateway
                  down with it — so this callback has to answer, not crash, for
                  any binary at all.
                  """)
              catch
                kind, reason ->
                  flunk("extract_resume/1 threw #{kind} #{inspect(reason)} on #{inspect(text)}")
              end

            assert match?(%LemonCore.ResumeToken{}, result) or is_nil(result),
                   "extract_resume/1 must return a ResumeToken or nil, got: #{inspect(result)}"
          end
        end

        test "is_resume_line/1 recognises a bare resume line and nothing else" do
          assert @engine.is_resume_line(@engine.format_resume(lemon_engine_token())),
                 "is_resume_line/1 must accept this engine's own format_resume/1 output"

          refute @engine.is_resume_line("")
          refute @engine.is_resume_line("Here is some prose about the run.")
        end
      end

      describe unquote(label <> " steering") do
        test "supports_steer?/0 answers a stable boolean" do
          assert is_boolean(@engine.supports_steer?())
          assert @engine.supports_steer?() == @engine.supports_steer?()
        end

        test "an engine that claims steering exports steer/2" do
          if @engine.supports_steer?() do
            assert function_exported?(@engine, :steer, 2),
                   "#{inspect(@engine)} answers supports_steer?/0 with true but does not export steer/2"
          end
        end
      end

      describe unquote(label <> " cancel/1") do
        test "is exported with arity 1" do
          assert function_exported?(@engine, :cancel, 1)
        end

        if unquote(unknown_ctx?) do
          test "tolerates a context it did not produce" do
            assert @engine.cancel(%{}) == :ok
            assert @engine.cancel(nil) == :ok
          end
        end
      end

      if unquote(run_probe != nil) do
        describe unquote(label <> " run lifecycle") do
          test "start_run/3 returns a ref, emits a started event, and cancels", context do
            job = LemonPlatformTest.resolve(@run_probe, context)

            assert %LemonGateway.Types.Job{} = job,
                   ":run_probe must return a %LemonGateway.Types.Job{}"

            assert {:ok, run_ref, cancel_ctx} = @engine.start_run(job, %{}, self()),
                   "start_run/3 must return {:ok, run_ref, cancel_ctx}"

            assert is_reference(run_ref), "run_ref must be a reference"

            assert_receive {:engine_event, ^run_ref, %{__event__: :started} = started},
                           @run_timeout,
                           "no started event arrived within #{@run_timeout}ms"

            assert started.engine == @engine.id(),
                   "the started event must carry this engine's id"

            assert @engine.cancel(cancel_ctx) == :ok,
                   "cancel/1 must return :ok for its own context"

            assert @engine.cancel(cancel_ctx) == :ok, "cancel/1 must be idempotent"
          end

          test "a completed event, when it arrives, is well formed", context do
            job = LemonPlatformTest.resolve(@run_probe, context)

            assert {:ok, run_ref, cancel_ctx} = @engine.start_run(job, %{}, self())

            receive do
              {:engine_event, ^run_ref, %{__event__: :completed} = completed} ->
                assert is_boolean(completed.ok), "completed.ok must be a boolean"
                assert completed.engine == @engine.id()
            after
              @run_timeout -> :ok
            end

            @engine.cancel(cancel_ctx)
          end
        end
      end

      if unquote(registry?) do
        describe unquote(label <> " registration round-trip") do
          setup do
            :ok = LemonPlatformTest.EngineCase.ensure_gateway_started!()
            LemonPlatformTest.EngineCase.restore_engines_on_exit()
            :ok
          end

          test "the engine registry can find the engine by id" do
            id = @engine.id()

            assert LemonGateway.EngineRegistry.register(@engine) == :ok
            assert LemonGateway.EngineRegistry.get_engine(id) == @engine
            assert LemonGateway.EngineRegistry.get_engine!(id) == @engine
            assert id in LemonGateway.EngineRegistry.list_engines()
          end

          test "registering twice is idempotent" do
            assert LemonGateway.EngineRegistry.register(@engine) == :ok
            assert LemonGateway.EngineRegistry.register(@engine) == :ok

            assert Enum.count(LemonGateway.EngineRegistry.list_engines(), &(&1 == @engine.id())) ==
                     1
          end
        end
      end

      defp lemon_engine_token do
        %LemonCore.ResumeToken{engine: @engine.id(), value: @resume_value}
      end
    end
  end

  @doc """
  Starts `:lemon_gateway` if it is not already running.

  When this function is the one that starts it, the gateway's health listener is
  disabled first, so running a compliance suite never binds a port. A gateway
  that was already running is left exactly as it was — the suite is a guest in
  that case, not the owner.
  """
  @spec ensure_gateway_started!() :: :ok
  def ensure_gateway_started! do
    unless gateway_running?() do
      Application.put_env(:lemon_gateway, :health_enabled, false)
    end

    case Application.ensure_all_started(:lemon_gateway) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise """
        LemonPlatformTest.EngineCase needs the :lemon_gateway application running
        to exercise the engine registry, but it failed to start: #{inspect(reason)}

        Start it in test_helper.exs, or pass `registry: false` to skip the
        registration round-trip.
        """
    end
  end

  @doc """
  Restores `:lemon_gateway, :engines` when the current test ends.

  `LemonGateway.EngineRegistry.register/1` writes the engine list back to
  application environment so it survives a registry restart. That is correct for
  a running system and wrong for a test suite, which would otherwise leave the
  engine under test registered for everything that runs after it in the same VM.
  """
  @spec restore_engines_on_exit() :: :ok
  def restore_engines_on_exit do
    original = Application.fetch_env(:lemon_gateway, :engines)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, engines} -> Application.put_env(:lemon_gateway, :engines, engines)
        :error -> Application.delete_env(:lemon_gateway, :engines)
      end
    end)

    :ok
  end

  defp gateway_running? do
    Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} ->
      app == :lemon_gateway
    end)
  end
end
