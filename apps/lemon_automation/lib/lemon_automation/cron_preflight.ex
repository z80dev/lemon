defmodule LemonAutomation.CronPreflight do
  @moduledoc """
  Pre-dispatch checks that run *before* a cron job reaches the router.

  Two independent guards, both applied only to agent-mode (prompt) jobs —
  command jobs involve no LLM and always pass:

  ## Model drift guard

  When a job is created without an explicit `model`, `CronManager` records the
  global default model of the day in `captured_default_model`. If that default
  later changes, the job would silently start running on a different model than
  the operator scheduled it against. The guard fails *closed*: the run is
  skipped with a `:model_drift` failure until the operator either pins a model
  (`CronManager.update(job_id, %{model: ...})`) or accepts the new default
  (`CronManager.refresh_captured_model/1`).

  It stays out of the way when there is nothing to compare: an explicitly
  pinned `model`, or a legacy job with no `captured_default_model`, passes. A
  *loader* failure (config raised) also passes, degraded — a broken config
  reader must not brick every scheduled job. Only detected drift fails closed.

  ## Readiness preflight

  Checks, in order, that the job can actually produce a delivered answer:
  target completeness, a routable session key, a live router, and at least one
  credential-ready provider *on the route this job will take* — a job pinned to
  `"<provider>:<model>"` is probed against that provider, not the global
  default. First failure wins. Probe failures (the status snapshot itself
  raising) degrade to `:ok` — preflight must not become the outage.

  ## Toggles

  Both guards default on, and both are overridable:

  - `LEMON_CRON_PREFLIGHT_ENABLED` / `config :lemon_automation, :cron_preflight,
    enabled: boolean()`
  - `LEMON_CRON_DRIFT_GUARD_ENABLED` / `config :lemon_automation,
    :cron_drift_guard, enabled: boolean()`

  An explicitly set env var wins over app env, which wins over the default.

  Injectables (via the `:cron_preflight` app-env keyword): `:status_mod`
  (default `LemonAgent.ModelRuntime.ProviderStatus`) and `:router_mod`
  (default `LemonRouter`). `config :lemon_automation, :cron_default_model_fun`
  takes a 0-arity fun returning `{:ok, model | nil} | :error`.
  """

  alias LemonAutomation.CronJob
  alias LemonCore.SessionKey

  require Logger

  @type failure :: %{class: atom(), detail: String.t()}

  @doc """
  Run the pre-dispatch checks for a job.
  """
  @spec check(CronJob.t()) :: :ok | {:skip, failure()}
  def check(%CronJob{} = job) do
    case CronJob.execution_mode(job) do
      :command ->
        :ok

      :agent ->
        with :ok <- drift_check(job), :ok <- readiness_check(job), do: :ok
    end
  end

  @doc """
  Compare the job's captured default model against the current global default.

  Fails closed on detected drift; passes when there is nothing to compare or
  when the config loader itself is unavailable.
  """
  @spec drift_check(CronJob.t()) :: :ok | {:skip, failure()}
  def drift_check(%CronJob{} = job) do
    cond do
      not drift_guard_enabled?() ->
        :ok

      is_binary(job.model) and String.trim(job.model) != "" ->
        :ok

      not is_binary(job.captured_default_model) ->
        :ok

      true ->
        compare_default_model(job)
    end
  end

  @doc """
  Check that the job can be dispatched and delivered right now.
  """
  @spec readiness_check(CronJob.t()) :: :ok | {:skip, failure()}
  def readiness_check(%CronJob{} = job) do
    if preflight_enabled?() do
      with :ok <- target_check(job),
           :ok <- session_check(job),
           :ok <- router_check(),
           :ok <- provider_check(job) do
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Resolve the current global default model.
  """
  @spec current_default_model() :: {:ok, binary() | nil} | :error
  def current_default_model do
    case Application.get_env(:lemon_automation, :cron_default_model_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> {:ok, LemonCore.Config.Modular.load().agent.default_model}
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Render a failure as the durable error string persisted on the skipped run.
  """
  @spec format_failure(failure()) :: binary()
  def format_failure(%{class: class, detail: detail}), do: "preflight:#{class}: #{detail}"

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp compare_default_model(%CronJob{} = job) do
    case current_default_model() do
      {:ok, current} ->
        captured = String.trim(job.captured_default_model)

        if is_binary(current) and String.trim(current) == captured do
          :ok
        else
          {:skip,
           %{
             class: :model_drift,
             detail:
               "global default model changed from \"#{captured}\" to " <>
                 "\"#{describe_model(current)}\" since this job was created; " <>
                 "pin a model via CronManager.update(job_id, %{model: ...}) or accept " <>
                 "the new default via CronManager.refresh_captured_model/1"
           }}
        end

      :error ->
        Logger.warning(
          "[CronPreflight] Could not resolve the default model; skipping drift guard for #{job.id}"
        )

        :ok
    end
  end

  defp describe_model(model) when is_binary(model), do: model
  defp describe_model(_model), do: "(unset)"

  defp target_check(%CronJob{} = job) do
    missing =
      [agent_id: job.agent_id, session_key: job.session_key, prompt: job.prompt]
      |> Enum.reject(fn {_key, value} -> present?(value) end)
      |> Enum.map(fn {key, _value} -> Atom.to_string(key) end)

    case missing do
      [] -> :ok
      keys -> {:skip, %{class: :invalid_target, detail: "missing #{Enum.join(keys, ", ")}"}}
    end
  end

  defp session_check(%CronJob{session_key: session_key}) do
    if routable_session?(session_key) do
      :ok
    else
      {:skip,
       %{
         class: :undeliverable,
         detail: "session_key #{inspect(session_key)} does not parse to a routable session"
       }}
    end
  end

  defp routable_session?(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{kind: kind} -> kind in [:main, :channel_peer]
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp routable_session?(_session_key), do: false

  defp router_check do
    if router_mod().available?() do
      :ok
    else
      {:skip, %{class: :router_unavailable, detail: "LemonRouter is not available"}}
    end
  rescue
    error ->
      Logger.warning("[CronPreflight] Router probe failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[CronPreflight] Router probe failed: #{inspect(reason)}")
      :ok
  end

  defp provider_check(%CronJob{} = job) do
    snapshot = status_mod().snapshot(probe_params(job))

    ready_count = Map.get(snapshot, "readyCount") || 0
    count = Map.get(snapshot, "count") || 0
    decision = get_in(snapshot, ["routing", "decision"])

    if ready_count == 0 or decision == "no_ready_provider" do
      {:skip, %{class: :no_ready_provider, detail: no_ready_detail(ready_count, count)}}
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("[CronPreflight] Provider probe failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[CronPreflight] Provider probe failed: #{inspect(reason)}")
      :ok
  end

  # The readiness probe must describe the route the job will actually take. A
  # job pinned to `"<provider>:<model>"` runs on that provider regardless of the
  # global default, so probing the default route would skip it for an outage it
  # is not exposed to. `"provider"` is the load-bearing half — ProviderRouting
  # only derives the requested provider from "requestedProvider"/"provider", so
  # a bare model id necessarily falls back to the global default route.
  defp probe_params(%CronJob{model: model}) when is_binary(model) do
    case model |> String.trim() |> String.split(":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        %{"provider" => provider, "model" => model_id}

      [model_id] when model_id != "" ->
        %{"model" => model_id}

      _ ->
        %{}
    end
  end

  defp probe_params(_job), do: %{}

  defp no_ready_detail(0, count), do: "0 of #{count} providers credential-ready"

  defp no_ready_detail(ready_count, count) do
    "no credential-ready provider on the route for this job " <>
      "(#{ready_count} of #{count} providers credential-ready overall)"
  end

  defp preflight_enabled?, do: toggle(:lemon_cron_preflight_enabled, :cron_preflight)
  defp drift_guard_enabled?, do: toggle(:lemon_cron_drift_guard_enabled, :cron_drift_guard)

  defp toggle(env_name, app_key) do
    case LemonCore.Env.get(env_name) do
      nil -> :lemon_automation |> Application.get_env(app_key, []) |> Keyword.get(:enabled, true)
      value -> value
    end
  end

  defp status_mod do
    preflight_config(:status_mod, LemonAgent.ModelRuntime.ProviderStatus)
  end

  defp router_mod do
    preflight_config(:router_mod, LemonRouter)
  end

  defp preflight_config(key, default) do
    :lemon_automation
    |> Application.get_env(:cron_preflight, [])
    |> Keyword.get(key, default)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
