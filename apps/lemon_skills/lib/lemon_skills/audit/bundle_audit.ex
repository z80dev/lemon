defmodule LemonSkills.Audit.BundleAudit do
  @moduledoc """
  Runs bundle-aware skill audits with persisted fingerprinted state.
  """

  require Logger

  alias LemonSkills.Bundle
  alias LemonSkills.Audit.{Engine, Finding, LlmReviewer, SkillLint, State}

  @type scope :: State.scope()
  @type entity_kind :: State.entity_kind()

  @spec audit(String.t(), scope(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit(bundle_path, scope, key, opts \\ [])
      when is_binary(bundle_path) and is_binary(key) and is_list(opts) do
    kind = Keyword.get(opts, :kind, :skill)
    force = Keyword.get(opts, :force, false)

    with {:ok, bundle_hash} <- Bundle.compute_hash(bundle_path) do
      fingerprint = audit_fingerprint(bundle_hash, opts)

      case maybe_cached(scope, kind, key, fingerprint, force) do
        {:ok, record} ->
          {:ok, Map.put(record, "cached", true)}

        :stale ->
          run_and_store(bundle_path, scope, kind, key, bundle_hash, fingerprint, opts)
      end
    end
  end

  @spec audit_fingerprint(String.t(), keyword()) :: String.t()
  def audit_fingerprint(bundle_hash, opts \\ []) when is_binary(bundle_hash) and is_list(opts) do
    llm = llm_config(opts)

    [
      "bundle_hash=#{bundle_hash}",
      "engine_version=#{Engine.version()}",
      "lint_version=#{SkillLint.version()}",
      "llm_policy_version=#{LlmReviewer.policy_version()}",
      "llm_enabled=#{llm.enabled}",
      "llm_model=#{llm.model || "none"}"
    ]
    |> Enum.join("\n")
    |> sha256_hex()
  end

  @spec audit_status(map()) :: :pass | :warn | :block
  def audit_status(%{"final_verdict" => verdict}), do: verdict_to_atom(verdict)
  def audit_status(%{final_verdict: verdict}), do: verdict_to_atom(verdict)

  @spec audit_findings(map()) :: [String.t()]
  def audit_findings(%{"combined_findings" => findings}) when is_list(findings), do: findings
  def audit_findings(%{combined_findings: findings}) when is_list(findings), do: findings
  def audit_findings(_), do: []

  defp maybe_cached(_scope, _kind, _key, _fingerprint, true), do: :stale

  defp maybe_cached(scope, kind, key, fingerprint, false) do
    case State.get(scope, kind, key) do
      {:ok, %{"audit_fingerprint" => ^fingerprint} = record} ->
        if cacheable_record?(record, fingerprint) do
          {:ok, record}
        else
          :stale
        end

      _ ->
        :stale
    end
  end

  defp run_and_store(bundle_path, scope, kind, key, bundle_hash, fingerprint, opts) do
    lint_result = SkillLint.lint_skill(bundle_path, include_audit: false)
    {static_verdict, static_findings} = Engine.audit_bundle(bundle_path)
    {llm_verdict, llm_findings, llm_model} = run_llm_review(bundle_path, static_findings, opts)

    lint_verdict = lint_verdict(lint_result.issues)
    final_verdict = worst_verdict([lint_verdict, static_verdict, llm_verdict])

    record = %{
      "key" => key,
      "kind" => Atom.to_string(kind),
      "bundle_hash" => bundle_hash,
      "audit_fingerprint" => fingerprint,
      "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "lint_valid" => lint_result.valid?,
      "lint_issues" => Enum.map(lint_result.issues, &encode_issue/1),
      "static_verdict" => Atom.to_string(static_verdict),
      "static_findings" => Enum.map(static_findings, &Finding.summary/1),
      "llm_verdict" => llm_verdict && Atom.to_string(llm_verdict),
      "llm_findings" => Enum.map(llm_findings, &Finding.summary/1),
      "llm_model" => llm_model,
      "llm_review_complete" => llm_review_complete?(opts, llm_verdict, llm_model),
      "llm_policy_version" => LlmReviewer.policy_version(),
      "final_verdict" => Atom.to_string(final_verdict),
      "approval_required" => final_verdict == :warn,
      "combined_findings" =>
        combined_findings(lint_result.issues, static_findings, llm_findings, final_verdict)
    }

    with :ok <- State.put(scope, kind, key, record) do
      {:ok, Map.put(record, "cached", false)}
    end
  end

  defp run_llm_review(bundle_path, static_findings, opts) do
    llm = llm_config(opts)

    if llm.enabled and is_binary(llm.model) and llm.model != "" do
      case Bundle.review_payload(bundle_path, max_bytes: llm.max_bundle_bytes) do
        {:ok, payload} ->
          review_opts =
            llm.extra
            |> Keyword.put(:model, llm.model)
            |> Keyword.put(:reviewer, llm.reviewer)
            |> maybe_put(:runner, llm.runner)

          summary =
            Enum.map_join(static_findings, "\n", fn finding ->
              "- " <> Finding.summary(finding)
            end)

          full_payload =
            if summary == "" do
              payload
            else
              payload <> "\n\nDeterministic findings:\n" <> summary
            end

          case llm.reviewer.review(full_payload, review_opts) do
            {:ok, {verdict, findings}} ->
              {verdict, findings, llm.model}

            {:error, reason} ->
              Logger.warning(
                "[BundleAudit] LLM audit unavailable for #{bundle_path}: #{inspect(reason)}"
              )

              {nil, [], llm.model}
          end

        {:error, reason} ->
          Logger.warning(
            "[BundleAudit] could not build LLM payload for #{bundle_path}: #{inspect(reason)}"
          )

          {nil, [], llm.model}
      end
    else
      {nil, [], llm.model}
    end
  end

  defp llm_config(opts) do
    env = Application.get_env(:lemon_skills, :audit_llm, [])
    llm_opts = Keyword.get(opts, :llm, [])

    %{
      enabled: Keyword.get(llm_opts, :enabled, Keyword.get(env, :enabled, false)),
      model: Keyword.get(llm_opts, :model, Keyword.get(env, :model)),
      reviewer:
        Keyword.get(
          llm_opts,
          :reviewer,
          Application.get_env(:lemon_skills, :audit_llm_reviewer, LlmReviewer)
        ),
      runner: Keyword.get(llm_opts, :runner),
      max_bundle_bytes:
        Keyword.get(llm_opts, :max_bundle_bytes, Keyword.get(env, :max_bundle_bytes, 32_768)),
      extra: llm_opts
    }
  end

  defp cacheable_record?(%{"llm_review_complete" => false}, _fingerprint), do: false
  defp cacheable_record?(_record, _fingerprint), do: true

  defp llm_review_complete?(opts, llm_verdict, llm_model) do
    llm = llm_config(opts)

    not (llm.enabled and is_binary(llm_model) and llm_model != "" and is_nil(llm_verdict))
  end

  defp lint_verdict(issues) do
    cond do
      Enum.any?(issues, &(&1.severity == :error)) -> :block
      Enum.any?(issues, &(&1.severity == :warn)) -> :warn
      true -> :pass
    end
  end

  defp encode_issue(issue) do
    %{
      "code" => Atom.to_string(issue.code),
      "message" => issue.message,
      "severity" => Atom.to_string(issue.severity)
    }
  end

  defp combined_findings(lint_issues, static_findings, llm_findings, final_verdict) do
    lint_messages =
      Enum.map(lint_issues, fn issue ->
        "lint/#{issue.code}: #{issue.message}"
      end)

    messages =
      lint_messages ++
        Enum.map(static_findings, &Finding.summary/1) ++
        Enum.map(llm_findings, &Finding.summary/1)

    if messages == [] and final_verdict != :pass do
      ["bundle_audit: #{final_verdict}"]
    else
      messages
    end
  end

  defp worst_verdict(verdicts) do
    cond do
      Enum.any?(verdicts, &(&1 == :block)) -> :block
      Enum.any?(verdicts, &(&1 == :warn)) -> :warn
      true -> :pass
    end
  end

  defp verdict_to_atom("block"), do: :block
  defp verdict_to_atom("warn"), do: :warn
  defp verdict_to_atom("pass"), do: :pass
  defp verdict_to_atom(:block), do: :block
  defp verdict_to_atom(:warn), do: :warn
  defp verdict_to_atom(_), do: :pass

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
