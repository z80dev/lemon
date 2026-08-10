defmodule LemonPlatformTest.EventsFixtures do
  @moduledoc """
  Builders for valid typed `LemonCore.Events.*` payloads, for use in tests.

  Tests that publish onto `LemonCore.Bus` used to hand-construct raw payload maps:

      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(run_id),
        LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "Done"}}, meta)
      )

  A raw map drifts from the contract the moment a field is added, renamed, or made
  mandatory — and it silently omits enforced keys (the `%{seq: 1, text: "..."}` delta
  map above is *missing its `run_id`*, which the typed `Delta` requires). These
  builders produce the real struct instead, so a test payload is exactly as valid as a
  production one:

      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(run_id),
        LemonCore.Event.new(:run_completed, EventsFixtures.run_completed(answer: "Done"), meta)
      )

  ## Defaults and overrides

  Every builder fills the payload's *enforced* keys with sensible sample values and
  leaves optional keys at their struct default, so a no-argument call is always a valid
  payload. Pass a keyword list or map to override any field:

      EventsFixtures.delta(text: "chunk two", seq: 2)
      EventsFixtures.run_started(run_id: "run_42", engine: "native")

  Unknown keys raise, because each builder ends in the payload's strict `new/1` — a typo
  in a test fixture should fail at the fixture, not surface as a `nil` field three
  assertions later.

  ## Nested payloads

  Payloads that wrap another payload accept **shorthand**: fields belonging to the nested
  struct can be passed at the top level and are routed inward. For `run_completed` the
  nested `LemonCore.Events.Completion` fields (`:ok`, `:answer`, `:error`, `:usage`, …)
  are lifted automatically:

      EventsFixtures.run_completed(ok: false, error: :timeout, duration_ms: 30)

  Pass `:completed` (a `Completion` struct or an attrs map) explicitly to build it
  yourself; an explicit `:completed` wins over any shorthand. The nested builders
  (`completion/1`, `action/1`, `approval_pending/1`) are public so you can compose them
  directly.

  This module is the fixture companion to `LemonPlatformTest.EventsCase`, which asserts
  the payload *contract*. Like that case, it needs `:lemon_core` (the `EventsCase ->
  lemon_core` row in the kit's dep table); anyone building event payloads already has it.
  """

  alias LemonCore.Events.{
    Action,
    ApprovalPending,
    ApprovalRequested,
    ApprovalResolved,
    Completion,
    CronJobChanged,
    CronRunCompleted,
    CronRunStarted,
    CronTick,
    Delta,
    RunCompleted,
    RunFailed,
    RunStarted
  }

  @typedoc "Field overrides for a builder, as a keyword list or map."
  @type overrides :: Enumerable.t()

  # Completion fields that `run_completed/1` accepts as top-level shorthand.
  @completion_fields Completion.fields()

  # --- run:<run_id> payloads -------------------------------------------------

  @doc """
  A `LemonCore.Events.RunStarted`. Enforced: `:run_id` (default `"run_test"`).
  """
  @spec run_started(overrides) :: RunStarted.t()
  def run_started(overrides \\ []) do
    build(RunStarted, %{run_id: "run_test"}, overrides)
  end

  @doc """
  A `LemonCore.Events.Delta` — a chunk of streamed text.

  Enforced: `:run_id` (default `"run_test"`), `:seq` (default `0`), `:text`
  (default `"delta"`). Unlike the legacy raw map, `run_id` lives *in the payload*
  where the typed contract requires it.
  """
  @spec delta(overrides) :: Delta.t()
  def delta(overrides \\ []) do
    build(Delta, %{run_id: "run_test", seq: 0, text: "delta"}, overrides)
  end

  @doc """
  A `LemonCore.Events.RunCompleted` wrapping a `Completion`.

  The nested completion is built from `:completed` when given, otherwise from any
  `Completion` shorthand fields passed at the top level (`:ok`, `:answer`, `:error`,
  `:usage`, …). Everything else (`:duration_ms`) is a `RunCompleted` field.

      EventsFixtures.run_completed()                      # ok: true, answer: "ok"
      EventsFixtures.run_completed(answer: "Done", duration_ms: 100)
      EventsFixtures.run_completed(ok: false, error: :timeout)
      EventsFixtures.run_completed(completed: EventsFixtures.completion(ok: false))
  """
  @spec run_completed(overrides) :: RunCompleted.t()
  def run_completed(overrides \\ []) do
    overrides = Map.new(overrides)

    completed =
      case Map.fetch(overrides, :completed) do
        {:ok, %Completion{} = completion} -> completion
        {:ok, attrs} -> completion(attrs)
        :error -> completion(Map.take(overrides, @completion_fields))
      end

    top =
      overrides
      |> Map.drop(@completion_fields)
      |> Map.put(:completed, completed)

    RunCompleted.new(top)
  end

  @doc """
  A `LemonCore.Events.RunFailed`.

  Enforced: `:run_id` (default `"run_test"`), `:reason` (default `:test_failure`).
  """
  @spec run_failed(overrides) :: RunFailed.t()
  def run_failed(overrides \\ []) do
    build(RunFailed, %{run_id: "run_test", reason: :test_failure}, overrides)
  end

  # --- exec_approvals payloads ----------------------------------------------

  @doc """
  A `LemonCore.Events.ApprovalPending` — the nested record inside the approval events.

  Enforced: `:id` (default `"appr_1"`), `:tool` (default `"bash"`).
  """
  @spec approval_pending(overrides) :: ApprovalPending.t()
  def approval_pending(overrides \\ []) do
    build(ApprovalPending, %{id: "appr_1", tool: "bash"}, overrides)
  end

  @doc """
  A `LemonCore.Events.ApprovalRequested`.

  Enforced: `:approval_id` (default `"appr_1"`) and `:pending` (default
  `approval_pending/1`). Pass `:pending` as an `ApprovalPending` struct or an attrs map.
  """
  @spec approval_requested(overrides) :: ApprovalRequested.t()
  def approval_requested(overrides \\ []) do
    overrides = Map.new(overrides)
    pending = resolve_pending(overrides) || approval_pending()

    attrs =
      %{approval_id: "appr_1"}
      |> Map.merge(overrides)
      |> Map.put(:pending, pending)

    ApprovalRequested.new(attrs)
  end

  @doc """
  A `LemonCore.Events.ApprovalResolved`.

  Enforced: `:approval_id` (default `"appr_1"`) and `:decision` (default `:approve_once`;
  see `LemonCore.Events.ApprovalResolved.decisions/0`). `:pending` is optional; pass an
  `ApprovalPending` struct or an attrs map to include it.
  """
  @spec approval_resolved(overrides) :: ApprovalResolved.t()
  def approval_resolved(overrides \\ []) do
    overrides = Map.new(overrides)

    attrs = Map.merge(%{approval_id: "appr_1", decision: :approve_once}, overrides)

    attrs =
      case resolve_pending(overrides) do
        nil -> Map.delete(attrs, :pending)
        pending -> Map.put(attrs, :pending, pending)
      end

    ApprovalResolved.new(attrs)
  end

  # --- cron payloads ---------------------------------------------------------

  @doc """
  A `LemonCore.Events.CronTick`. Enforced: `:timestamp_ms` (default a fixed sample).
  """
  @spec cron_tick(overrides) :: CronTick.t()
  def cron_tick(overrides \\ []) do
    build(CronTick, %{timestamp_ms: 1_754_800_000_000}, overrides)
  end

  @doc """
  A `LemonCore.Events.CronRunStarted`.

  Enforced: `:cron_run_id` (default `"cron_run_1"`), `:job_id` (default `"job_1"`).
  """
  @spec cron_run_started(overrides) :: CronRunStarted.t()
  def cron_run_started(overrides \\ []) do
    build(CronRunStarted, %{cron_run_id: "cron_run_1", job_id: "job_1"}, overrides)
  end

  @doc """
  A `LemonCore.Events.CronRunCompleted`.

  Enforced: `:cron_run_id` (default `"cron_run_1"`), `:job_id` (default `"job_1"`).
  Defaults `:status` to `:ok`.
  """
  @spec cron_run_completed(overrides) :: CronRunCompleted.t()
  def cron_run_completed(overrides \\ []) do
    build(CronRunCompleted, %{cron_run_id: "cron_run_1", job_id: "job_1", status: :ok}, overrides)
  end

  @doc """
  A `LemonCore.Events.CronJobChanged` (the `cron_job_created/updated/deleted` payload).

  Enforced: `:action` (default `:created`), `:job_id` (default `"job_1"`).
  """
  @spec cron_job_changed(overrides) :: CronJobChanged.t()
  def cron_job_changed(overrides \\ []) do
    build(CronJobChanged, %{action: :created, job_id: "job_1"}, overrides)
  end

  # --- nested payloads -------------------------------------------------------

  @doc """
  A `LemonCore.Events.Completion` — the terminal result nested in `run_completed`.

  Enforced: `:ok` (default `true`). Defaults `:answer` to `"ok"`.
  """
  @spec completion(overrides) :: Completion.t()
  def completion(overrides \\ []) do
    build(Completion, %{ok: true, answer: "ok"}, overrides)
  end

  @doc """
  A `LemonCore.Events.Action` — the nested record inside `engine_action`.

  Enforced: `:id` (default `"act_1"`), `:kind` (default `:tool`), `:title`
  (default `"Example action"`).
  """
  @spec action(overrides) :: Action.t()
  def action(overrides \\ []) do
    build(Action, %{id: "act_1", kind: :tool, title: "Example action"}, overrides)
  end

  # --- internals -------------------------------------------------------------

  defp build(module, defaults, overrides) do
    module.new(Map.merge(defaults, Map.new(overrides)))
  end

  defp resolve_pending(overrides) do
    case Map.fetch(overrides, :pending) do
      {:ok, %ApprovalPending{} = pending} -> pending
      {:ok, attrs} -> approval_pending(attrs)
      :error -> nil
    end
  end
end
