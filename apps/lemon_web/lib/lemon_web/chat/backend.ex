defmodule LemonWeb.Chat.Backend do
  @moduledoc """
  Control-plane calls made by the chat workspace.

  Every operation goes through `LemonWeb.Rpc` (the same methods, scopes and
  projections the TUI uses). Results are normalized into small tagged tuples
  so the LiveViews never branch on wire shapes, and errors only ever carry the
  control plane's safe display message.

  Tests may intercept individual methods with
  `Application.put_env(:lemon_web, :chat_rpc_stub, fn method, params -> ... end)`;
  the stub returns `:passthrough` for methods it does not handle.
  """

  require Logger

  alias LemonWeb.Rpc

  @type error :: %{code: atom(), message: String.t(), details: map() | nil}

  @doc "Raw RPC call honoring the test stub."
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, error()}
  def call(method, params) do
    case Application.get_env(:lemon_web, :chat_rpc_stub) do
      stub when is_function(stub, 2) ->
        case stub.(method, params) do
          :passthrough -> Rpc.call(method, params)
          {:ok, _} = ok -> ok
          {:error, error} -> {:error, Rpc.normalize_error(error)}
        end

      _ ->
        Rpc.call(method, params)
    end
  rescue
    error ->
      Logger.warning("chat rpc #{method} raised class=#{inspect(error.__struct__)}")
      {:error, %{code: :unavailable, message: "Lemon runtime is unavailable", details: nil}}
  catch
    :exit, _ ->
      {:error, %{code: :unavailable, message: "Lemon runtime is unavailable", details: nil}}
  end

  # ── Runs ────────────────────────────────────────────────────────────────

  @doc """
  Active run for `session_key`. Only an explicit "no run" answer is `:none`;
  every failure or unexpected answer is `:unavailable` (callers keep any known
  running state instead of assuming idle).
  """
  @spec active_run(String.t()) :: {:ok, String.t()} | :none | :unavailable
  def active_run(session_key) do
    case call("sessions.active", %{"sessionKey" => session_key}) do
      {:ok, %{"sessionKey" => ^session_key, "runId" => run_id}}
      when is_binary(run_id) and run_id != "" ->
        {:ok, run_id}

      {:ok, %{"sessionKey" => ^session_key, "runId" => nil}} ->
        :none

      _ ->
        :unavailable
    end
  end

  @doc """
  The shared bounded recovery authority. `:retry` is a raced owner read, not
  an empty session; callers retain their last known state and reconcile again.
  """
  @spec snapshot(String.t(), String.t() | nil) ::
          {:ok, map()} | :retry | {:error, error()}
  def snapshot(session_key, cwd) do
    params = put_present(%{"sessionKey" => session_key, "limit" => 100}, "cwd", cwd)

    case call("sessions.snapshot", params) do
      {:ok,
       %{
         "status" => "ok",
         "sessionKey" => ^session_key,
         "identity" => %{"sessionKey" => ^session_key},
         "snapshot" => snapshot
       } = result}
      when is_map(snapshot) ->
        {:ok, result}

      {:ok, %{"status" => "retry"}} ->
        :retry

      {:error, error} ->
        {:error, error}

      _ ->
        {:error, unavailable()}
    end
  end

  @doc "Submits a prompt with `chat.send`. `opts`: `:cwd`, `:agent_id`, `:images`, `:queue_mode`."
  @spec send_prompt(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :outcome_unknown | error()}
  def send_prompt(session_key, prompt, opts \\ []) do
    params =
      %{"sessionKey" => session_key, "prompt" => prompt}
      |> put_present("cwd", opts[:cwd])
      |> put_present("agentId", opts[:agent_id])
      |> put_present("queueMode", opts[:queue_mode] && to_string(opts[:queue_mode]))
      |> then(fn params ->
        case opts[:images] do
          [_ | _] = images -> Map.put(params, "images", images)
          _ -> params
        end
      end)

    case call("chat.send", params) do
      {:ok, %{"runId" => run_id}} when is_binary(run_id) ->
        {:ok, run_id}

      {:ok, _} ->
        {:error, %{code: :internal_error, message: "Unexpected chat.send response", details: nil}}

      {:error, %{details: %{"retrySafe" => false}}} ->
        {:error, :outcome_unknown}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Requests a stop of exactly `run_id`."
  @spec abort(String.t()) :: :ok | {:error, :not_sent | :outcome_unknown}
  def abort(run_id) do
    case call("chat.abort", %{"runId" => run_id}) do
      {:ok, %{"aborted" => true}} ->
        :ok

      {:ok, %{"summary" => %{"dispatchStatus" => "outcome_unknown"}}} ->
        {:error, :outcome_unknown}

      _ ->
        {:error, :not_sent}
    end
  end

  # ── Transcript ──────────────────────────────────────────────────────────

  @doc """
  Private-chat transcript: `chat.history` with full text (unredacted, operator
  chat only — management surfaces keep using redacted previews).
  """
  @spec history(String.t(), String.t() | nil, pos_integer()) :: {:ok, [map()]} | {:error, error()}
  def history(session_key, cwd, limit \\ 200) do
    params =
      %{"sessionKey" => session_key, "limit" => limit, "includeFullText" => true}
      |> put_present("cwd", cwd)

    case call("chat.history", params) do
      {:ok, %{"messages" => messages}} when is_list(messages) -> {:ok, messages}
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  # ── Approvals ───────────────────────────────────────────────────────────

  @doc "Pending approvals that belong to `session_key`."
  @spec pending_approvals(String.t()) :: {:ok, [map()]} | {:error, error()}
  def pending_approvals(session_key) do
    case call("exec.approvals.get", %{}) do
      {:ok, %{"pending" => pending}} when is_list(pending) ->
        {:ok, Enum.filter(pending, &(is_map(&1) and &1["sessionKey"] == session_key))}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec resolve_approval(String.t(), String.t()) :: :ok | {:error, error()}
  def resolve_approval(approval_id, decision) do
    case call("exec.approval.resolve", %{"approvalId" => approval_id, "decision" => decision}) do
      {:ok, %{"resolved" => true}} -> :ok
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  # ── Session state ───────────────────────────────────────────────────────

  @spec plan(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def plan(session_key, cwd, action) when action in ["status", "enter", "exit"] do
    case call("sessions.plan", %{"sessionKey" => session_key, "cwd" => cwd, "action" => action}) do
      {:ok, %{"sessionKey" => ^session_key, "plan" => %{"mode" => mode} = plan}}
      when mode in ["plan", "code"] ->
        {:ok,
         %{
           mode: mode,
           path: if(is_binary(plan["path"]), do: plan["path"]),
           content: if(is_binary(plan["content"]), do: plan["content"])
         }}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec context(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def context(session_key, cwd) do
    case call("sessions.context", %{"sessionKey" => session_key, "cwd" => cwd}) do
      {:ok, %{"sessionKey" => ^session_key} = context} -> {:ok, context}
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Manual compaction. Blocking: call from `start_async`."
  @spec compact(String.t(), String.t() | nil) :: :ok | {:error, error()}
  def compact(session_key, cwd) do
    case call("sessions.compact", put_present(%{"sessionKey" => session_key}, "cwd", cwd)) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Routing patch: `model`, `thinkingLevel` and/or `toolPolicy`."
  @spec patch(String.t(), map()) :: :ok | {:error, error()}
  def patch(session_key, patch) when is_map(patch) do
    case call("sessions.patch", Map.put(patch, "sessionKey", session_key)) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Metadata patch: `title`, `pinned` and/or `archived`."
  @spec metadata_patch(String.t(), map()) :: :ok | {:error, error()}
  def metadata_patch(session_key, patch) when is_map(patch) do
    case call("sessions.metadata.patch", Map.put(patch, "sessionKey", session_key)) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Forks `session_key`; returns the child key. Never retried automatically."
  @spec fork(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:outcome_unknown, String.t() | nil} | error()}
  def fork(session_key, cwd) do
    case call("sessions.fork", %{"sessionKey" => session_key, "cwd" => cwd}) do
      {:ok, %{"sessionKey" => child, "sourceSessionKey" => ^session_key}} when is_binary(child) ->
        {:ok, child}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, %{details: %{"retrySafe" => false} = details}} ->
        {:error, {:outcome_unknown, details["sessionKey"]}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Routing facts for the header: title/pin/archive plus the model, provider,
  context window and thinking level the next run resolves to.
  """
  @spec session_meta(String.t()) :: {:ok, map()} | {:error, error()}
  def session_meta(session_key) do
    case call("session.detail", %{"sessionKey" => session_key, "limit" => 1, "historyLimit" => 1}) do
      {:ok, %{"session" => session}} when is_map(session) ->
        {:ok,
         %{
           title: string(session["title"]),
           pinned: session["pinned"] == true,
           archived: session["archived"] == true,
           model: string(session["model"]),
           model_override: string(session["modelOverride"]),
           provider: string(session["provider"]),
           context_window: integer(session["contextWindow"]),
           thinking_level: string(session["thinkingLevel"]),
           agent_id: string(session["agentId"])
         }}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The session's stored tool-policy override. `sessions.patch` writes it and the
  router reads it per run; no read method returns it, so this reads the same
  policy row in-process and projects only the profile and approval modes.
  """
  @spec tool_policy(String.t()) :: %{profile: String.t() | nil, ask: boolean()}
  def tool_policy(session_key) do
    policy =
      case LemonCore.PolicyStore.get_session(session_key) do
        %{} = stored -> Map.get(stored, :tool_policy) || Map.get(stored, "tool_policy") || %{}
        _ -> %{}
      end

    approvals = field(policy, :approvals) || %{}

    %{
      profile: string(field(policy, :profile)),
      ask:
        is_map(approvals) and
          Enum.any?(approvals, fn {_tool, mode} -> to_string(mode) == "always" end)
    }
  rescue
    _ -> %{profile: nil, ask: false}
  catch
    :exit, _ -> %{profile: nil, ask: false}
  end

  @spec models() :: {:ok, [map()]} | {:error, error()}
  def models do
    case call("models.list", %{"discoverOpenAI" => false}) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         models
         |> Enum.filter(&(is_map(&1) and is_binary(&1["id"])))
         |> Enum.map(fn model ->
           %{
             id: model["id"],
             provider: string(model["provider"]) || "unknown",
             name: string(model["name"]) || model["id"],
             context_window: integer(model["contextWindow"]),
             thinking: model["supportsThinking"] == true,
             vision: model["supportsVision"] == true
           }
         end)}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  # ── Session directory ───────────────────────────────────────────────────

  @doc "Durable sessions (`sessions.list`), projected for navigation."
  @spec sessions(map()) :: {:ok, [map()], non_neg_integer()} | {:error, error()}
  def sessions(params \\ %{}) do
    case call("sessions.list", Map.merge(%{"limit" => 50}, params)) do
      {:ok, %{"sessions" => sessions} = result} when is_list(sessions) ->
        rows =
          sessions
          |> Enum.filter(&(is_map(&1) and is_binary(&1["sessionKey"])))
          |> Enum.map(fn row ->
            %{
              key: row["sessionKey"],
              agent_id: string(row["agentId"]),
              title: string(row["title"]),
              pinned: row["pinned"] == true,
              archived: row["archived"] == true,
              updated_at_ms: integer(row["updatedAtMs"]),
              run_count: integer(row["runCount"]) || 0,
              model: string(row["model"])
            }
          end)

        {:ok, rows, integer(result["total"]) || length(rows)}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Keys of sessions with an in-flight run, mapped to the run id."
  @spec active_sessions() :: {:ok, %{String.t() => String.t() | nil}} | {:error, error()}
  def active_sessions do
    case call("sessions.active.list", %{"limit" => 200}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        {:ok,
         sessions
         |> Enum.filter(&(is_map(&1) and is_binary(&1["sessionKey"])))
         |> Map.new(&{&1["sessionKey"], string(&1["runId"])})}

      {:ok, _} ->
        {:error, unavailable()}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Profiles for the new-session picker: id and display name only."
  @spec profiles() :: {:ok, [map()]} | {:error, error()}
  def profiles do
    case call("profiles.roster", %{}) do
      {:ok, %{"profiles" => profiles}} when is_list(profiles) -> {:ok, project_profiles(profiles)}
      {:ok, profiles} when is_list(profiles) -> {:ok, project_profiles(profiles)}
      {:ok, _} -> {:error, unavailable()}
      {:error, error} -> {:error, error}
    end
  end

  defp project_profiles(profiles) do
    profiles
    |> Enum.filter(&(is_map(&1) and is_binary(&1["id"])))
    |> Enum.map(&%{id: &1["id"], name: string(&1["name"]) || &1["id"]})
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp unavailable,
    do: %{code: :unavailable, message: "Lemon returned an unexpected response.", details: nil}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp string(value) when is_binary(value) and value != "", do: value

  defp string(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp string(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil
end
