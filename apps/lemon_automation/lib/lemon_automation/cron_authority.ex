defmodule LemonAutomation.CronAuthority do
  @moduledoc """
  Launcher authority of a prompt cron job (`CronJob.authority`) and the policy
  floor every run of the job executes under.

  A job created from an agent session (the `cron` tool) records
  `%{"version" => 1, "owner" => principal, "policy" => policy_map}`:

    * `owner` - the creating session's principal (its trusted session key).
      Agent sessions reach only jobs whose owner is their own principal; jobs
      without a record (operator-created) are reachable only from operator
      surfaces.
    * `policy` - the session's effective tool policy: the router-resolved
      intersection of the agent, channel (including the group approval floor),
      session (including peer and profile denials such as `no_external`) and
      runtime layers, narrowed by any delegated execution context. An owner
      update intersects it with the updater's current policy.

  No update path replaces or removes the record. Runs are not bounded by the
  record alone: a job whose base session is a channel peer session
  (chat-created jobs, `/remind` reminders) also runs under the policy that chat
  currently gets (`run_policy/1`).
  """

  alias LemonCore.{SessionKey, ToolPolicy}

  @version 1

  @doc """
  Authority recorded for a job launched by the agent session principal
  `owner`, from the session's tool options (`:tool_policy`,
  `:execution_context`). A session without any policy is unrestricted and
  records full access.
  """
  @spec from_session(binary(), keyword()) :: map()
  def from_session(owner, opts) when is_binary(owner) and owner != "" and is_list(opts),
    do: record(owner, caller_policy(opts))

  @doc "Validates a persisted record; `nil` means no recorded authority."
  @spec validate(term()) :: {:ok, map() | nil} | {:error, :cron_authority_invalid}
  def validate(nil), do: {:ok, nil}

  def validate(%{"version" => @version, "owner" => owner, "policy" => policy} = authority)
      when map_size(authority) == 3 and is_binary(owner) and owner != "" do
    case ToolPolicy.parse(policy) do
      {:ok, parsed} -> {:ok, record(owner, parsed)}
      {:error, _} -> {:error, :cron_authority_invalid}
    end
  end

  def validate(_authority), do: {:error, :cron_authority_invalid}

  @doc "Whether the agent session principal `owner` owns the job's valid record."
  @spec owned_by?(term(), term()) :: boolean()
  def owned_by?(authority, owner) when is_binary(owner) and owner != "" do
    match?({:ok, %{"owner" => ^owner}}, validate(authority))
  end

  def owned_by?(_authority, _owner), do: false

  @doc "Narrows a recorded authority with the policy of the owner session updating the job."
  @spec restrict(map(), keyword()) :: {:ok, map()} | {:error, :cron_authority_invalid}
  def restrict(authority, opts) when is_list(opts) do
    case validate(authority) do
      {:ok, %{"owner" => owner, "policy" => policy}} ->
        case ToolPolicy.restrict(policy, caller_policy(opts)) do
          {:ok, restricted} -> {:ok, record(owner, restricted)}
          {:error, _} -> {:ok, record(owner, ToolPolicy.deny_all())}
        end

      _ ->
        {:error, :cron_authority_invalid}
    end
  end

  @doc """
  Tool policy of the agent session triggering a manual run
  (`CronManager.run_now_from_session/2`), recorded on the run as
  `meta.trigger_policy`.
  """
  @spec trigger_policy(keyword()) :: map()
  def trigger_policy(opts) when is_list(opts), do: ToolPolicy.to_map(caller_policy(opts))

  @doc """
  Policy floor for one run of `job`: the intersection of

    * the recorded authority,
    * the run's `meta.trigger_policy`, when an agent session triggered it, and
    * for a job whose base session is a channel peer session, the live policy
      of that chat (`LemonRouter.Policy.resolve_validated_for_run/1` with
      `origin: :channel`: channel restrictions, the group approval floor for
      any peer that is not a direct message, and the chat session's policy).

  `nil` when none applies. A malformed record or trigger policy, or an
  unreadable policy layer, is an error, never an unrestricted run.
  """
  @spec run_policy(LemonAutomation.CronJob.t(), LemonAutomation.CronRun.t() | nil) ::
          {:ok, ToolPolicy.t() | nil} | {:error, :cron_authority_invalid | :policy_unavailable}
  def run_policy(job, run \\ nil) do
    with {:ok, authority} <- validate(job.authority),
         {:ok, trigger} <- run_trigger_policy(run),
         {:ok, chat} <- chat_policy(job) do
      intersect_all(Enum.reject([authority && authority["policy"], trigger, chat], &is_nil/1))
    end
  end

  defp intersect_all([]), do: {:ok, nil}

  defp intersect_all([first | rest]) do
    with {:ok, parsed} <- parsed(first) do
      Enum.reduce_while(rest, {:ok, parsed}, fn policy, {:ok, acc} ->
        case restricted(acc, policy) do
          {:ok, _} = ok -> {:cont, ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp parsed(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :cron_authority_invalid}
    end
  end

  defp run_trigger_policy(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :trigger_policy, Map.get(meta, "trigger_policy")) do
      nil -> {:ok, nil}
      policy -> parsed(policy)
    end
  end

  defp run_trigger_policy(_run), do: {:ok, nil}

  defp chat_policy(%{session_key: session_key, agent_id: agent_id}) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{kind: :channel_peer} = parsed ->
        chat_session_key = SessionKey.rebuild(%{parsed | sub_id: nil})

        case LemonRouter.Policy.resolve_validated_for_run(%{
               agent_id: agent_id,
               session_key: chat_session_key,
               origin: :channel,
               channel_context: %{
                 channel_id: parsed.channel_id,
                 account_id: parsed.account_id,
                 peer_kind: parsed.peer_kind,
                 peer_id: parsed.peer_id,
                 thread_id: parsed.thread_id
               }
             }) do
          {:ok, policy} -> {:ok, policy}
          {:error, _} -> {:error, :policy_unavailable}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp chat_policy(_job), do: {:ok, nil}

  defp restricted(left, right) do
    case ToolPolicy.restrict(left, right) do
      {:ok, policy} -> {:ok, policy}
      {:error, _} -> {:error, :cron_authority_invalid}
    end
  end

  defp record(owner, policy),
    do: %{"version" => @version, "owner" => owner, "policy" => ToolPolicy.to_map(policy)}

  # The invoking session's effective tool policy (its own policy narrowed by
  # any delegated execution context); full access only when it has none.
  defp caller_policy(opts) do
    context_policy =
      case Keyword.get(opts, :execution_context) do
        %{tool_policy: policy} -> policy
        _ -> nil
      end

    case Enum.reject([Keyword.get(opts, :tool_policy), context_policy], &is_nil/1) do
      [] ->
        ToolPolicy.from_profile(:full_access)

      [policy] ->
        policy_or_deny_all(ToolPolicy.parse(policy))

      [policy, context_policy] ->
        policy_or_deny_all(ToolPolicy.restrict(policy, context_policy))
    end
  end

  defp policy_or_deny_all({:ok, policy}), do: policy
  defp policy_or_deny_all({:error, _}), do: ToolPolicy.deny_all()
end
