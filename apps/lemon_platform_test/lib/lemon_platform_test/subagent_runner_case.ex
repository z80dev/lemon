defmodule LemonPlatformTest.SubagentRunnerCase do
  @moduledoc """
  Compliance suite for `LemonCore.SubagentRunner` implementations.

  ## What a subagent runner is

  A runner executes a delegated subtask for the agent's `task` tool. It is the
  smaller sibling of `LemonGateway.Engine`: an engine answers a run the gateway
  scheduled and streams events to a sink process, while a runner is started
  inside an already-running agent turn and hands back a lazy event stream the
  tool folds into a tool result. The two behaviours stay separate on purpose;
  they share only the `LemonCore.RunEvents` vocabulary.

  Runners register themselves from their own application's `start/2`, and
  `LemonCore.SubagentRegistry` is what the agent reads — which engine ids exist,
  what to say about each in the tool description the model sees, and which
  module to call. That is why the registry round-trip below is on by default:
  "works standalone, invisible to the tool" is the failure this suite exists to
  catch.

  ## The contract in one page

    * `id/0` — a slug matching `~r/^[a-z][a-z0-9_-]*$/`, not `"default"` or
      `"help"`, stable across calls. It is what the tool's `engine` parameter
      accepts, so treat it as permanent.
    * `describe/0` — `%{summary: String.t(), caveats: [String.t()]}`, rendered
      as list items in the tool description. No newlines in either. `:caveats`
      is where vendor quirks belong ("ignores `model`"), so that the agent never
      has to know them.
    * `start/1` — `{:ok, session}` or `{:error, reason}`, never a raise for an
      option it does not recognise: callers pass one option set to every runner.
    * `events/1` — an enumerable of `{:started, token}`, `{:action, map, phase,
      opts}`, `{:completed, answer, opts}` and `{:error, reason}` that
      *terminates*, because a tool call is blocked on it.
    * `cancel/1` (optional) — total and idempotent, including for a session it
      never produced.
    * `resume_format/0` (optional) — the engine's resume-command syntax, as a
      `LemonCore.ResumeFormat`, registered under `id/0` and able to read back
      the command it printed. Omitting it means the platform reads and prints
      the generic `<engine> resume <value>` for this engine.
    * `default_policy/0` (optional) — the tool policy profile children get.
    * `routable?/0` (optional) — whether `id/0` is also a router-visible engine.

  ## Running the suite

      defmodule MyApp.SubagentComplianceTest do
        use LemonPlatformTest.SubagentRunnerCase, async: false, runner: MyApp.Subagent
      end

  That runs the static contract and the registry round-trip; nothing executes.
  Pass a `:run_probe` to also exercise a real run, which is only worth doing
  when the run is free and offline — a fake CLI on `PATH`, an in-process stub:

      defmodule MyApp.SubagentComplianceTest do
        use LemonPlatformTest.SubagentRunnerCase,
          async: false,
          runner: MyApp.Subagent,
          run_probe: {__MODULE__, :start_opts}

        def start_opts(_context), do: [prompt: "ping", cwd: System.tmp_dir!()]
      end

  The probe asserts the run *terminates* and ends on a terminal event. It
  deliberately does not assert success: a runner whose executor is missing must
  still complete its stream with `{:completed, _, ok: false}` or `{:error, _}`
  rather than hang, and that is the property worth pinning.

  ## Options

    * `:runner` — required, the module under test.
    * `:registry` — round-trip through `LemonCore.SubagentRegistry`.
      Default `true`. Requires `:lemon_core` to be running; the entry is
      removed again when the test ends. Suites using it must be `async: false`.
    * `:run_probe` — `{Module, :function}` returning the keyword list passed to
      `start/1`, called with the test context. Off by default.
    * `:run_timeout` — milliseconds the probe may take. Default `10_000`.
    * `:resume_sample` — a token value your `resume_format/0` pattern accepts,
      used to check the print/parse round-trip. Default `"ses_abc123"`.
  """

  use ExUnit.CaseTemplate

  @reserved_ids ~w(default help)

  @doc "Runner ids `LemonCore.SubagentRegistry` refuses to register."
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @doc """
  Unregisters `id` when the current test ends, and restores the persisted
  runner list.

  `LemonCore.SubagentRegistry.register/1` writes its module list back to
  application environment so it survives a registry restart. Correct for a
  running system, wrong for a suite, which would otherwise leave the module
  under test registered for everything that runs after it in the same VM.
  """
  @spec restore_runners_on_exit(String.t()) :: :ok
  def restore_runners_on_exit(id) when is_binary(id) do
    original = Application.fetch_env(:lemon_core, :subagent_runners)
    previously_registered? = match?({:ok, _}, LemonCore.SubagentRegistry.fetch(id))

    ExUnit.Callbacks.on_exit(fn ->
      unless previously_registered?, do: LemonCore.SubagentRegistry.unregister(id)

      case original do
        {:ok, runners} -> Application.put_env(:lemon_core, :subagent_runners, runners)
        :error -> Application.delete_env(:lemon_core, :subagent_runners)
      end
    end)

    :ok
  end

  @doc """
  Checks a runner's `resume_format/0` against `sample`, a token value its
  pattern is expected to accept.

  `:ok`, or `{:error, message}` naming the half of the round-trip that broke:
  printing a command the format cannot recognise, or recognising one it then
  reads a different value out of, leaves the platform pinning resume lines it
  cannot resolve.
  """
  @spec check_resume_format(module(), String.t()) :: :ok | {:error, String.t()}
  def check_resume_format(runner, sample) when is_binary(sample) do
    format = runner.resume_format()

    cond do
      not is_struct(format, LemonCore.ResumeFormat) ->
        {:error, "resume_format/0 must return a LemonCore.ResumeFormat, got: #{inspect(format)}"}

      format.engine != runner.id() ->
        {:error,
         "resume_format/0 is registered under its :engine, which must be id/0 " <>
           "(#{inspect(runner.id())}), got: #{inspect(format.engine)}"}

      true ->
        check_resume_round_trip(format, sample)
    end
  end

  defp check_resume_round_trip(format, sample) do
    line = LemonCore.ResumeFormat.render(format, sample)

    cond do
      not LemonCore.ResumeFormat.resume_line?(format, line) ->
        {:error, "a line resume_format/0 printed is not recognised as one: #{inspect(line)}"}

      LemonCore.ResumeFormat.capture(format, line) != sample ->
        {:error, "resume_format/0 does not read #{inspect(sample)} back out of #{inspect(line)}"}

      true ->
        :ok
    end
  end

  @doc """
  Drains `events/1` until a terminal event, returning the events seen.

  Raises when the stream does not end within `timeout_ms`, which is the failure
  a blocked tool call would otherwise show up as.
  """
  @spec drain_events(module(), term(), pos_integer()) :: [term()]
  def drain_events(runner, session, timeout_ms) do
    task = Task.async(fn -> runner.events(session) |> Enum.to_list() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, events} ->
        events

      _ ->
        raise "events/1 did not terminate within #{timeout_ms}ms"
    end
  end

  using opts do
    LemonPlatformTest.require_dep!("SubagentRunnerCase", LemonCore.SubagentRunner, :lemon_core)

    runner = Keyword.fetch!(opts, :runner)
    registry? = Keyword.get(opts, :registry, true)
    run_probe = Keyword.get(opts, :run_probe)
    run_timeout = Keyword.get(opts, :run_timeout, 10_000)
    resume_sample = Keyword.get(opts, :resume_sample, "ses_abc123")
    label = Macro.to_string(runner)

    quote do
      @runner unquote(runner)
      @run_probe unquote(run_probe)
      @run_timeout unquote(run_timeout)
      @resume_sample unquote(resume_sample)

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonCore.SubagentRunner" do
          assert LemonPlatformTest.declares_behaviour?(@runner, LemonCore.SubagentRunner),
                 "#{inspect(@runner)} must declare `@behaviour LemonCore.SubagentRunner`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@runner, LemonCore.SubagentRunner) == []
        end
      end

      describe unquote(label <> " id/0") do
        test "is a stable slug the subagent registry accepts" do
          id = @runner.id()

          assert is_binary(id), "id/0 must return a binary, got: #{inspect(id)}"

          assert Regex.match?(~r/^[a-z][a-z0-9_-]*$/, id),
                 "runner id #{inspect(id)} must match ~r/^[a-z][a-z0-9_-]*$/"

          refute id in LemonPlatformTest.SubagentRunnerCase.reserved_ids(),
                 "runner id #{inspect(id)} is reserved by LemonCore.SubagentRegistry"

          assert @runner.id() == id, "id/0 must return the same value on every call"
        end
      end

      describe unquote(label <> " describe/0") do
        test "renders as tool-description list items" do
          description = @runner.describe()

          assert {:ok, normalized} = LemonCore.SubagentRunner.normalize_description(description),
                 "describe/0 returned something the tool description cannot render: " <>
                   inspect(description)

          assert normalized.summary != ""

          assert @runner.describe() == description,
                 "describe/0 must return the same value on every call"
        end
      end

      describe unquote(label <> " optional callbacks") do
        # `apply/3` throughout: these callbacks are optional, so naming them
        # directly would make the compiler warn about the runners that
        # correctly omit them.
        test "default_policy/0, when exported, names a policy profile" do
          if function_exported?(@runner, :default_policy, 0) do
            assert is_atom(apply(@runner, :default_policy, [])),
                   "default_policy/0 must return an atom naming a tool policy profile"
          end
        end

        test "routable?/0, when exported, answers a stable boolean" do
          if function_exported?(@runner, :routable?, 0) do
            assert is_boolean(apply(@runner, :routable?, []))
            assert apply(@runner, :routable?, []) == apply(@runner, :routable?, [])
          end
        end

        test "resume_format/0, when exported, reads back what it printed" do
          if function_exported?(@runner, :resume_format, 0) do
            assert LemonPlatformTest.SubagentRunnerCase.check_resume_format(
                     @runner,
                     @resume_sample
                   ) == :ok
          end
        end

        test "cancel/1, when exported, tolerates a session it did not produce" do
          if function_exported?(@runner, :cancel, 1) do
            assert apply(@runner, :cancel, [%{}]) == :ok,
                   "cancel/1 must be total: end its clauses with `def cancel(_session), do: :ok`"
          end
        end
      end

      if unquote(registry?) do
        describe unquote(label <> " registration round-trip") do
          setup do
            LemonPlatformTest.SubagentRunnerCase.restore_runners_on_exit(@runner.id())
            :ok
          end

          test "the registry can find the runner by id" do
            id = @runner.id()

            assert LemonCore.SubagentRegistry.register(@runner) == :ok
            assert LemonCore.SubagentRegistry.module(id) == @runner
            assert id in LemonCore.SubagentRegistry.list_ids()
          end

          test "the entry carries the runner's own description and policy" do
            assert LemonCore.SubagentRegistry.register(@runner) == :ok
            assert {:ok, entry} = LemonCore.SubagentRegistry.fetch(@runner.id())

            {:ok, described} = LemonCore.SubagentRunner.normalize_description(@runner.describe())

            assert entry.summary == described.summary
            assert entry.caveats == described.caveats
            assert entry.policy == LemonCore.SubagentRegistry.policy(@runner.id())
          end

          test "registering twice is idempotent" do
            assert LemonCore.SubagentRegistry.register(@runner) == :ok
            assert LemonCore.SubagentRegistry.register(@runner) == :ok

            assert Enum.count(LemonCore.SubagentRegistry.list_ids(), &(&1 == @runner.id())) == 1
          end
        end
      end

      if unquote(run_probe != nil) do
        describe unquote(label <> " run lifecycle") do
          test "start/1 runs and events/1 terminates on a terminal event", context do
            opts = LemonPlatformTest.resolve(@run_probe, context)

            assert is_list(opts), ":run_probe must return a keyword list for start/1"

            assert {:ok, session} = @runner.start(opts),
                   "start/1 must return {:ok, session} or {:error, reason}"

            events =
              LemonPlatformTest.SubagentRunnerCase.drain_events(@runner, session, @run_timeout)

            assert Enum.any?(events, &match?({:completed, _answer, _opts}, &1)) or
                     Enum.any?(events, &match?({:error, _reason}, &1)),
                   "the event stream ended without a {:completed, _, _} or {:error, _}: " <>
                     inspect(events)

            if function_exported?(@runner, :cancel, 1) do
              assert apply(@runner, :cancel, [session]) == :ok,
                     "cancel/1 must return :ok for a session that already finished"
            end
          end

          test "start/1 ignores options it does not recognise", context do
            opts = LemonPlatformTest.resolve(@run_probe, context)

            assert {:ok, session} =
                     @runner.start(Keyword.put(opts, :not_a_real_option, :ignored)),
                   "start/1 must ignore unknown options: every runner is handed the same set"

            LemonPlatformTest.SubagentRunnerCase.drain_events(@runner, session, @run_timeout)
          end
        end
      end
    end
  end
end
