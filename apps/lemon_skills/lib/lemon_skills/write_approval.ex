defmodule LemonSkills.WriteApproval do
  @moduledoc """
  Adapts agent-authored memory mutations to the shared execution approval flow.
  Preview data is bounded, redacted and escaped; the full mutation and its owning
  workspace are bound by a digest, never by the lossy display projection.
  Unattended callers cannot consume stored approval grants.
  """

  @scopes [
    :once,
    :session,
    :agent,
    :node,
    :global,
    :approve_once,
    :approve_session,
    :approve_agent,
    :approve_global
  ]

  def required?(domain, cwd) when domain in [:memory, :skills] do
    config = LemonCore.Config.load(cwd)
    Map.get(Map.fetch!(config, domain), :write_approval, false) != false
  end

  def check(domain, tool, params, context, tool_call_id) do
    if required?(domain, context[:cwd]) do
      if interactive?(context) do
        request(tool, params, context, tool_call_id)
      else
        {:error,
         "Human approval is required; no interactive approver is available. Nothing was written."}
      end
    else
      :ok
    end
  end

  def context(opts) do
    opts = Map.new(opts)
    Map.merge(opts, opts[:approval_context] || %{})
  end

  defp interactive?(context) do
    session = context[:session_id]
    execution = context[:execution_context]
    origin = if is_map(execution), do: get_in(execution, [Access.key(:provenance, %{}), :origin])

    context[:unattended] != true and origin not in ["cron", "automation", "background", :cron] and
      is_binary(session) and session != "" and channel_supported?(context[:session_key])
  end

  defp channel_supported?(key) when is_binary(key) do
    case LemonCore.SessionKey.parse(key) do
      %{kind: :channel_peer, channel_id: channel} -> channel in ["telegram", "discord"]
      _ -> true
    end
  end

  defp channel_supported?(_), do: true

  defp request(tool, params, context, tool_call_id) do
    action = %{
      "type" => "durable_write",
      "preview_trust" => "untrusted data (escaped)",
      "preview" => preview(params),
      "mutation_digest" =>
        digest(
          {tool, params,
           Map.take(context, [
             :cwd,
             :workspace_dir,
             :invocation_context_key,
             :memory_context_key
           ])}
        )
    }

    request = context[:approval_request_fun] || (&LemonCore.ExecApprovals.request/1)

    result =
      try do
        request.(%{
          run_id: context[:run_id],
          session_id: context[:session_id],
          session_key: context[:session_key],
          agent_id: context[:agent_id],
          invocation_context_key: context[:invocation_context_key],
          tool_call_id: tool_call_id,
          tool: tool,
          action: action,
          rationale: "Human approval required for durable #{tool} mutation",
          expires_in_ms: approval_timeout(context)
        })
      catch
        _, _ -> {:error, :approval_unavailable}
      end

    case result do
      {:ok, :approved, scope} when scope in @scopes -> :ok
      {:ok, :denied} -> {:error, "The user declined the write. Nothing was written."}
      _ -> {:error, "Human approval was unavailable or expired. Nothing was written."}
    end
  end

  defp approval_timeout(context) do
    case context[:timeout_ms] do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 60_000
    end
  end

  @doc false
  def project_action(params) do
    %{
      "preview_trust" => "untrusted data (escaped)",
      "preview" => preview(params),
      "mutation_digest" => digest(params)
    }
  end

  defp preview(params) do
    params
    |> Map.take(
      ~w(target action name scope file_path text replaces content file_content old_string new_string replace_all)
    )
    |> Map.new(fn {key, value} -> {key, display(value)} end)
  end

  defp display(value) when is_binary(value) do
    value
    |> LemonCore.Redact.text(drop_keys: true)
    |> String.slice(0, 2_000)
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, fn char ->
      "\\u{" <> (char |> String.to_charlist() |> hd() |> Integer.to_string(16)) <> "}"
    end)
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.replace(["<", ">", "&", "`"], fn char ->
      "\\u" <> (char |> :binary.first() |> Integer.to_string(16) |> String.pad_leading(4, "0"))
    end)
  end

  defp display(value) when is_boolean(value) or is_nil(value), do: value
  defp display(_), do: "[invalid value]"

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
