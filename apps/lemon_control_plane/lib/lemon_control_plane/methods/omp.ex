defmodule LemonControlPlane.Methods.OmpSupport do
  @moduledoc false

  # Shared validation and error projection for the `omp.*` methods. `LemonOmp`
  # owns the delegate; these handlers only bound parameters, choose the
  # operator owner and map its error reasons onto control-plane codes.

  alias LemonControlPlane.Protocol.Errors

  @max_id_bytes 128
  @max_cwd_bytes 4_096
  @max_message_bytes 16_384
  @max_limit 100
  @max_option_bytes 128

  @doc "Operator owner for reads and control of existing sessions."
  def read_opts, do: [owner: :any]

  @doc "Operator owner recorded on sessions the control plane starts."
  def start_opts, do: [owner: %{kind: :operator}]

  def id(params), do: bounded_string(params, "id", @max_id_bytes)
  def cwd(params), do: bounded_string(params, "cwd", @max_cwd_bytes)

  def limit(%{"limit" => nil}), do: {:ok, nil}

  def limit(%{"limit" => limit}) when is_integer(limit) and limit in 1..@max_limit,
    do: {:ok, limit}

  def limit(%{"limit" => _limit}),
    do: invalid_params("limit must be an integer between 1 and #{@max_limit}", "limit")

  def limit(_params), do: {:ok, nil}

  def message(%{"message" => message}) when is_binary(message) do
    cond do
      byte_size(message) > @max_message_bytes ->
        invalid_params("message must be at most 16 KiB", "message")

      String.trim(message) == "" ->
        invalid_params("message is required", "message")

      true ->
        {:ok, message}
    end
  end

  def message(_params), do: invalid_params("message is required", "message")

  def mode(%{"mode" => mode}) when mode in [nil, "steer"], do: {:ok, :steer}
  def mode(%{"mode" => "followUp"}), do: {:ok, :follow_up}
  def mode(%{"mode" => "redirect"}), do: {:ok, :redirect}

  def mode(%{"mode" => _mode}),
    do: invalid_params("mode must be steer, followUp or redirect", "mode")

  def mode(_params), do: {:ok, :steer}

  @doc "Optional bounded string options passed through to `LemonOmp.start/2`."
  def start_options(params) do
    specs = [
      {"model", "model", &valid_model?/1},
      {"thinking", "thinking", &(&1 in ~w(off minimal low medium high xhigh max auto))},
      {"approvalMode", "approval_mode", &(&1 in ~w(always-ask write yolo))},
      {"isolate", "isolate", &is_boolean/1},
      {"continue", "continue", &is_boolean/1}
    ]

    Enum.reduce_while(specs, {:ok, %{}}, fn {key, target, valid?}, {:ok, acc} ->
      case Map.fetch(params, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          if valid?.(value),
            do: {:cont, {:ok, Map.put(acc, target, value)}},
            else: {:halt, invalid_params("#{key} is invalid", key)}
      end
    end)
  end

  defp valid_model?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_option_bytes and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/, value)

  def string(params, key, max), do: bounded_string(params, key, max)

  def prompt(params, optional \\ false) do
    if optional and not Map.has_key?(params, "prompt"),
      do: {:ok, nil},
      else: bounded_string(params, "prompt", @max_message_bytes)
  end

  def bounded_limit(params, max) do
    case Map.fetch(params, "limit") do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 1 and value <= max -> {:ok, value}
      _ -> invalid_params("limit must be an integer between 1 and #{max}", "limit")
    end
  end

  def continuation(params) do
    if params["continue"] == true and Map.has_key?(params, "prompt"),
      do: invalid_params("continue cannot accompany prompt", "continue"),
      else: :ok
  end

  @doc """
  Run a `LemonOmp` call; a crashed or missing integration is reported as
  unavailable rather than leaking an exit or exception term onto the wire.
  """
  def call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc "Map a `LemonOmp` error reason onto a control-plane error tuple."
  def error(reason, context \\ %{})

  def error(:outcome_unknown, context) do
    {:error,
     Errors.error(
       :unavailable,
       LemonOmp.error_message(:outcome_unknown),
       Map.merge(context, %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false})
     )}
  end

  # A start whose prompt omp never acknowledged: the invocation exists and may
  # be working, so return its fixed id for reconciliation.
  def error({:outcome_unknown, id}, context) when is_binary(id) do
    {:error,
     Errors.error(
       :unavailable,
       LemonOmp.error_message({:outcome_unknown, id}),
       Map.merge(context, %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false, "id" => id})
     )}
  end

  def error(reason, _context) do
    {code, public_code, details} = classify(reason)

    {:error,
     Errors.error(
       code,
       LemonOmp.error_message(reason),
       Map.merge(details, %{"code" => public_code})
     )}
  end

  defp classify(:not_installed), do: {:unavailable, "OMP_NOT_INSTALLED", %{}}
  defp classify(:unavailable), do: {:unavailable, "OMP_UNAVAILABLE", %{}}
  defp classify(:startup_failed), do: {:unavailable, "OMP_STARTUP_FAILED", %{}}
  defp classify({:startup_failed, _message}), do: {:unavailable, "OMP_STARTUP_FAILED", %{}}

  defp classify(:not_a_git_repo),
    do: {:invalid_params, "OMP_NOT_A_GIT_REPO", %{"field" => "cwd"}}

  defp classify(:worktree_failed), do: {:unavailable, "OMP_WORKTREE_FAILED", %{}}
  defp classify({:catalog_failed, _}), do: {:unavailable, "OMP_CATALOG_FAILED", %{}}

  defp classify({:invalid_task, index, _}),
    do: {:invalid_params, "OMP_INVALID_TASK", %{"index" => index}}

  defp classify({:partially_applied, applied, step, _}),
    do:
      {:conflict, "OMP_PARTIALLY_APPLIED",
       %{"applied" => applied, "failedStep" => step, "retrySafe" => false}}

  defp classify(:not_found), do: {:not_found, "OMP_SESSION_NOT_FOUND", %{}}
  defp classify(:invalid_cwd), do: {:invalid_params, "OMP_INVALID_PARAMS", %{"field" => "cwd"}}

  defp classify(:invalid_prompt),
    do: {:invalid_params, "OMP_INVALID_PARAMS", %{"field" => "prompt"}}

  defp classify(:invalid_message),
    do: {:invalid_params, "OMP_INVALID_PARAMS", %{"field" => "message"}}

  defp classify(:invalid_params), do: {:invalid_params, "OMP_INVALID_PARAMS", %{}}
  defp classify(:not_running), do: {:conflict, "OMP_SESSION_NOT_RUNNING", %{}}
  defp classify(:not_ready), do: {:conflict, "OMP_SESSION_NOT_READY", %{}}
  defp classify(:no_active_turn), do: {:conflict, "OMP_NO_ACTIVE_TURN", %{}}
  defp classify({:rejected, _message}), do: {:conflict, "OMP_REJECTED", %{}}
  defp classify(:too_many_sessions), do: {:conflict, "OMP_TOO_MANY_SESSIONS", %{}}
  defp classify(_reason), do: {:internal_error, "OMP_REQUEST_FAILED", %{}}

  defp bounded_string(params, key, max_bytes) do
    case params[key] do
      value when is_binary(value) and value != "" and byte_size(value) <= max_bytes ->
        {:ok, value}

      value when is_binary(value) and value != "" ->
        invalid_params("#{key} is too long", key)

      _value ->
        {:error, Errors.invalid_request("#{key} is required")}
    end
  end

  defp invalid_params(message, field),
    do: {:error, Errors.invalid_params(message, %{"field" => field})}
end

defmodule LemonControlPlane.Methods.OmpStatus do
  @moduledoc "Reports whether omp is installed, its version and live-session counts."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.status"

  @impl true
  def scopes, do: [:read]

  # The first call probes `omp --version` (bounded at a few seconds).
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(_params, _ctx) do
    case Support.call(fn -> {:ok, LemonOmp.status()} end) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> Support.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsList do
  @moduledoc "Lists live and recently ended omp sessions, newest first."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, limit} <- Support.limit(params) do
      opts =
        Support.read_opts()
        |> Keyword.put(:include_ended, params["includeEnded"] != false)
        |> then(&if(limit, do: Keyword.put(&1, :limit, limit), else: &1))

      case Support.call(fn -> {:ok, LemonOmp.list(opts)} end) do
        {:ok, sessions} -> {:ok, %{"sessions" => sessions}}
        {:error, reason} -> Support.error(reason)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsGet do
  @moduledoc "Returns one omp session snapshot with a bounded plain-text summary."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, id} <- Support.id(params || %{}) do
      result =
        Support.call(fn ->
          with {:ok, session} <- LemonOmp.get(id, Support.read_opts()),
               {:ok, summary} <- LemonOmp.summary(id, Support.read_opts()) do
            {:ok, %{"session" => session, "summary" => summary}}
          end
        end)

      case result do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> Support.error(reason)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsDiscover do
  @moduledoc "Lists omp's stored sessions for a workspace (read-only)."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.discover"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, cwd} <- Support.cwd(params),
         {:ok, limit} <- Support.limit(params) do
      opts = if limit, do: [limit: limit], else: []

      case Support.call(fn -> LemonOmp.discover(cwd, opts) end) do
        {:ok, sessions} -> {:ok, %{"sessions" => sessions}}
        {:error, reason} -> Support.error(reason)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsStart do
  @moduledoc "Starts an omp process for a prompt in a workspace."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.start"

  @impl true
  def scopes, do: [:write]

  # Returns once omp acknowledged the prompt (bounded by its ready + command
  # timeouts), so it must not hold the WebSocket process.
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, cwd} <- Support.cwd(params),
         {:ok, prompt} <- Support.prompt(params),
         {:ok, options} <- Support.start_options(params) do
      start = Map.merge(options, %{"cwd" => cwd, "prompt" => prompt})

      case Support.call(fn -> LemonOmp.start(start, Support.start_opts()) end) do
        {:ok, session} -> {:ok, %{"session" => session}}
        {:error, reason} -> Support.error(reason)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsResume do
  @moduledoc "Reopens a stored omp session under a new invocation id."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support
  alias LemonControlPlane.Protocol.Errors

  @max_session_id_bytes 64

  @impl true
  def name, do: "omp.sessions.resume"

  @impl true
  def scopes, do: [:write]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, omp_session_id} <- omp_session_id(params),
         {:ok, cwd} <- Support.cwd(params),
         {:ok, prompt} <- Support.prompt(params, true),
         :ok <- Support.continuation(params),
         {:ok, options} <- Support.start_options(params) do
      start = Map.merge(options, %{"cwd" => cwd, "prompt" => prompt, "resume" => omp_session_id})

      case Support.call(fn -> LemonOmp.start(start, Support.start_opts()) end) do
        {:ok, session} -> {:ok, %{"session" => session}}
        {:error, reason} -> Support.error(reason)
      end
    end
  end

  defp omp_session_id(%{"ompSessionId" => id})
       when is_binary(id) and id != "" and byte_size(id) <= @max_session_id_bytes,
       do: {:ok, id}

  defp omp_session_id(%{"ompSessionId" => id}) when is_binary(id) and id != "",
    do: {:error, Errors.invalid_params("ompSessionId is too long", %{"field" => "ompSessionId"})}

  defp omp_session_id(_params), do: {:error, Errors.invalid_request("ompSessionId is required")}
end

defmodule LemonControlPlane.Methods.OmpSessionsSend do
  @moduledoc """
  Steers the running turn, queues a follow-up, or starts a new turn on an idle
  session. Acknowledged only after omp confirms.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, id} <- Support.id(params),
         {:ok, message} <- Support.message(params),
         {:ok, mode} <- Support.mode(params) do
      case Support.call(fn -> LemonOmp.send_message(id, message, mode, Support.read_opts()) end) do
        {:ok, %{"delivery" => delivery}} -> {:ok, %{"accepted" => true, "delivery" => delivery}}
        {:error, reason} -> Support.error(reason, %{"id" => id})
        _other -> Support.error(:outcome_unknown, %{"id" => id})
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsCancel do
  @moduledoc "Aborts the in-flight omp turn; the process stays open for follow-ups."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.cancel"

  @impl true
  def scopes, do: [:write]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    with {:ok, id} <- Support.id(params || %{}) do
      case Support.call(fn -> LemonOmp.cancel(id, Support.read_opts()) end) do
        {:ok, %{"cancelled" => true}} -> {:ok, %{"cancelled" => true}}
        {:error, reason} -> Support.error(reason, %{"id" => id})
        _other -> Support.error(:outcome_unknown, %{"id" => id})
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsClose do
  @moduledoc "Ends an omp process; its session file stays resumable."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.OmpSupport, as: Support

  @impl true
  def name, do: "omp.sessions.close"

  @impl true
  def scopes, do: [:write]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    with {:ok, id} <- Support.id(params || %{}) do
      case Support.call(fn -> LemonOmp.close(id, Support.read_opts()) end) do
        {:ok, session} -> {:ok, %{"session" => session}}
        {:error, reason} -> Support.error(reason, %{"id" => id})
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsStartMany do
  @moduledoc "Starts a bounded, prevalidated batch of omp workers."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.OmpSupport, as: Support
  alias LemonControlPlane.Protocol.Errors

  def name, do: "omp.sessions.startMany"
  def scopes, do: [:write]
  def dispatch_mode, do: :async

  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, defaults} <- Support.start_options(Map.take(params, ["isolate"])),
         {:ok, tasks} <- tasks(params["tasks"], defaults) do
      case Support.call(fn -> LemonOmp.start_many(tasks, Support.start_opts()) end) do
        {:error, reason} ->
          Support.error(reason)

        results when is_list(results) ->
          {:ok,
           %{
             "results" =>
               Enum.with_index(results, fn result, index ->
                 case result do
                   {:ok, session} ->
                     %{"index" => index, "session" => session}

                   {:error, reason} ->
                     {:error, {_, message, details}} = Support.error(reason)

                     error =
                       details
                       |> Map.delete("code")
                       |> Map.merge(%{"code" => details["code"], "message" => message})

                     %{"index" => index, "error" => error}
                 end
               end)
           }}
      end
    end
  end

  defp tasks(tasks, defaults) when is_list(tasks) and length(tasks) in 1..8 do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      result =
        if is_map(task) do
          with {:ok, cwd} <- Support.cwd(task),
               {:ok, prompt} <- Support.prompt(task),
               {:ok, options} <-
                 Support.start_options(
                   Map.take(task, ["model", "thinking", "approvalMode", "isolate"])
                 ) do
            {:ok,
             defaults |> Map.merge(options) |> Map.merge(%{"cwd" => cwd, "prompt" => prompt})}
          end
        else
          {:error, :invalid_params}
        end

      case result do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        {:error, _} -> {:halt, Support.error({:invalid_task, index, :invalid_params})}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      error -> error
    end
  end

  defp tasks(_, _),
    do: {:error, Errors.invalid_params("tasks must contain 1 to 8 tasks", %{"field" => "tasks"})}
end

defmodule LemonControlPlane.Methods.OmpModels do
  @moduledoc "Lists the bounded omp model catalog, cheapest first."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.OmpSupport, as: Support
  alias LemonControlPlane.Protocol.Errors
  def name, do: "omp.models"
  def scopes, do: [:read]
  def dispatch_mode, do: :async

  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, limit} <- Support.bounded_limit(params, 200),
         {:ok, opts} <- options(params) do
      opts = if limit, do: Keyword.put(opts, :limit, limit), else: opts

      case Support.call(fn -> LemonOmp.models(opts) end) do
        {:ok, models} -> {:ok, %{"models" => models}}
        {:error, reason} -> Support.error(reason)
      end
    end
  end

  defp options(params) do
    Enum.reduce_while(
      [{"query", :query}, {"provider", :provider}, {"freeOnly", :free_only}],
      {:ok, []},
      fn {key, target}, {:ok, acc} ->
        case Map.fetch(params, key) do
          :error ->
            {:cont, {:ok, acc}}

          {:ok, value} when key == "freeOnly" and is_boolean(value) ->
            {:cont, {:ok, [{target, value} | acc]}}

          {:ok, value}
          when key != "freeOnly" and is_binary(value) and byte_size(value) in 1..128 ->
            {:cont, {:ok, [{target, value} | acc]}}

          _ ->
            {:halt, {:error, Errors.invalid_params("#{key} is invalid", %{"field" => key})}}
        end
      end
    )
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsSubagent do
  @moduledoc "Reads a bounded, sanitized child transcript."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.OmpSupport, as: Support
  def name, do: "omp.sessions.subagent"
  def scopes, do: [:read]
  def dispatch_mode, do: :async

  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, id} <- Support.id(params),
         {:ok, child} <- Support.string(params, "subagentId", 128),
         {:ok, limit} <- Support.bounded_limit(params, 50) do
      opts =
        if limit, do: Keyword.put(Support.read_opts(), :limit, limit), else: Support.read_opts()

      case Support.call(fn -> LemonOmp.subagent(id, child, opts) end) do
        {:ok, transcript} ->
          {:ok, %{"id" => id, "subagentId" => child, "transcript" => transcript}}

        {:error, reason} ->
          Support.error(reason, %{"id" => id})
      end
    end
  end
end

defmodule LemonControlPlane.Methods.OmpSessionsConfigure do
  @moduledoc "Changes a live worker's model and/or thinking level."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.OmpSupport, as: Support
  alias LemonControlPlane.Protocol.Errors
  def name, do: "omp.sessions.configure"
  def scopes, do: [:write]
  def dispatch_mode, do: :async

  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, id} <- Support.id(params),
         {:ok, options} <- Support.start_options(Map.take(params, ["model", "thinking"])) do
      if map_size(options) == 0 do
        {:error, Errors.invalid_params("model or thinking is required", %{"field" => "model"})}
      else
        case Support.call(fn -> LemonOmp.configure(id, options, Support.read_opts()) end) do
          {:ok, session} -> {:ok, %{"session" => session}}
          {:error, reason} -> Support.error(reason, %{"id" => id})
        end
      end
    end
  end
end
