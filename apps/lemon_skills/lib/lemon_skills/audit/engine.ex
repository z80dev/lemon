defmodule LemonSkills.Audit.Engine do
  @moduledoc """
  Audits a skill bundle for security and safety concerns.

  Scans the SKILL.md content (and any listed scripts) for patterns that are
  known to be destructive, suspicious, or exploitable.  Each rule returns zero
  or more `LemonSkills.Audit.Finding` structs.

  ## Verdicts

  | Verdict  | Meaning |
  |----------|---------|
  | `:pass`  | No issues found — skill may be installed freely. |
  | `:warn`  | One or more soft findings — requires explicit user approval. |
  | `:block` | One or more hard findings — installation must be refused, not overrideable. |

  The overall verdict is the worst finding: block > warn > pass.

  ## Rules

  | Rule                   | Severity | Signals |
  |------------------------|----------|---------|
  | `destructive_commands` | `:warn`  | `rm -rf`, `dd`, `mkfs`, `fdisk`, `shred` |
  | `remote_exec`          | `:block` | `curl … | bash/sh/python`, `wget … | sh` |
  | `exfiltration`         | `:block` | Piping sensitive paths to curl/wget/nc/http |
  | `path_traversal`       | `:warn`  | `../../../`, `/etc/passwd`, `/etc/shadow` |
  | `symlink_escape`       | `:block` | `ln -s /etc/passwd`, `ln -s /root` |

  ## Usage

      case LemonSkills.Audit.Engine.audit_content(skill_md_content) do
        {:pass, []} ->
          # safe to install
        {:warn, findings} ->
          # ask user to approve
        {:block, findings} ->
          # refuse installation
      end
  """

  alias LemonSkills.Audit.Finding
  alias LemonSkills.Bundle
  alias LemonSkills.Entry
  alias LemonSkills.Audit.LlmReviewer

  @type verdict :: :pass | :warn | :block
  @version 2

  @doc "Version tag for cache invalidation when deterministic audit rules change."
  @spec version() :: pos_integer()
  def version, do: @version

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Audit the raw SKILL.md content string.

  Returns `{verdict, findings}` where `verdict` is the overall worst severity.
  """
  @spec audit_content(String.t()) :: {verdict(), [Finding.t()]}
  def audit_content(content) when is_binary(content) do
    audit_content(content, [])
  end

  @doc """
  Audit the raw SKILL.md content string with optional overrides.

  Supported options:
  - `:llm` — keyword list with `:enabled`, `:model`, `:reviewer`, and `:runner`
  """
  @spec audit_content(String.t(), keyword()) :: {verdict(), [Finding.t()]}
  def audit_content(content, opts) when is_binary(content) and is_list(opts) do
    findings =
      []
      |> run_rule(&check_destructive_commands/1, content)
      |> run_rule(&check_remote_exec/1, content)
      |> run_rule(&check_exfiltration/1, content)
      |> run_rule(&check_path_traversal/1, content)
      |> run_rule(&check_symlink_escape/1, content)
      |> Kernel.++(run_llm_review(content, opts))

    {overall_verdict(findings), findings}
  end

  @doc """
  Audit a skill `Entry` by reading its SKILL.md content.

  Returns `{verdict, findings}`.  When the SKILL.md cannot be read, returns
  `{:warn, [finding]}` indicating the content could not be verified.
  """
  @spec audit_entry(Entry.t()) :: {verdict(), [Finding.t()]}
  def audit_entry(%Entry{} = entry) do
    audit_entry(entry, [])
  end

  @spec audit_entry(Entry.t(), keyword()) :: {verdict(), [Finding.t()]}
  def audit_entry(%Entry{} = entry, opts) when is_list(opts) do
    audit_bundle(entry.path, opts)
  end

  @doc """
  Audit all auditable text files in a skill bundle.
  """
  @spec audit_bundle(String.t(), keyword()) :: {verdict(), [Finding.t()]}
  def audit_bundle(skill_dir, opts \\ []) when is_binary(skill_dir) and is_list(opts) do
    case Bundle.files(skill_dir) do
      {:ok, files} ->
        content =
          files
          |> Enum.filter(& &1.text?)
          |> Enum.map_join("\n\n", fn file ->
            case File.read(file.full_path) do
              {:ok, body} -> "### #{file.path}\n\n#{body}"
              {:error, _} -> ""
            end
          end)

        if String.trim(content) == "" do
          {:pass, []}
        else
          audit_content(content, opts)
        end

      {:error, reason} ->
        finding =
          Finding.warn(
            "unreadable_content",
            "Could not read bundle for audit: #{inspect(reason)}. " <>
              "Skill may be missing or permissions are incorrect."
          )

        {:warn, [finding]}
    end
  end

  @doc """
  Apply audit results to an `Entry`, updating `audit_status` and `audit_findings`.
  """
  @spec apply_to_entry(Entry.t(), {verdict(), [Finding.t()]}) :: Entry.t()
  def apply_to_entry(%Entry{} = entry, {verdict, findings}) do
    finding_summaries = Enum.map(findings, &Finding.summary/1)

    audit_status =
      case verdict do
        :pass -> :pass
        :warn -> :warn
        :block -> :block
      end

    %{entry | audit_status: audit_status, audit_findings: finding_summaries}
  end

  # ── Rule runners ─────────────────────────────────────────────────────────────

  defp run_rule(acc, rule_fn, content) do
    acc ++ rule_fn.(content)
  end

  defp run_llm_review(content, opts) do
    llm_opts = Keyword.get(opts, :llm, [])
    enabled = Keyword.get(llm_opts, :enabled, audit_llm_enabled?())

    if enabled do
      reviewer = Keyword.get(llm_opts, :reviewer, configured_llm_reviewer())

      review_opts =
        llm_opts
        |> Keyword.put_new(:model, configured_llm_model())

      case reviewer.review(content, review_opts) do
        {:ok, {_verdict, findings}} ->
          findings

        {:error, reason} ->
          [
            Finding.warn(
              "llm_audit_unavailable",
              "LLM audit enabled but could not complete: #{format_review_error(reason)}",
              nil
            )
          ]
      end
    else
      []
    end
  end

  defp audit_llm_enabled? do
    Application.get_env(:lemon_skills, :audit_llm, [])
    |> Keyword.get(:enabled, false)
  end

  defp configured_llm_model do
    Application.get_env(:lemon_skills, :audit_llm, [])
    |> Keyword.get(:model)
  end

  defp configured_llm_reviewer do
    Application.get_env(:lemon_skills, :audit_llm_reviewer, LlmReviewer)
  end

  defp format_review_error({:unknown_model, model}), do: "unknown model #{inspect(model)}"

  defp format_review_error({:unknown_provider, provider}),
    do: "unknown provider #{inspect(provider)}"

  defp format_review_error({:invalid_json, _reason}), do: "reviewer did not return valid JSON"
  defp format_review_error(:missing_model), do: "no audit_llm model configured"
  defp format_review_error(:invalid_payload), do: "reviewer returned an invalid payload"
  defp format_review_error(reason) when is_binary(reason), do: reason
  defp format_review_error(reason), do: inspect(reason)

  # ── Rule: destructive_commands ───────────────────────────────────────────────

  @destructive_patterns [
    {~r/\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b/, "rm -rf (recursive force delete)"},
    {~r/\brm\s+-[a-zA-Z]*f[a-zA-Z]*r\b/, "rm -rf variant"},
    {~r/\bdd\s+if=/, "dd with input file (disk write)"},
    {~r/\bmkfs\b/, "mkfs (filesystem creation)"},
    {~r/\bfdisk\b/, "fdisk (partition editor)"},
    {~r/\bshred\b/, "shred (secure delete)"},
    {~r/\bformat\s+[A-Z]:/i, "Windows format command"},
    {~r/\bsudo\s+rm\s+-[a-zA-Z]*r/, "sudo rm -r (recursive delete with elevated privileges)"}
  ]

  defp check_destructive_commands(content) do
    @destructive_patterns
    |> Enum.flat_map(fn {pattern, desc} ->
      case Regex.run(pattern, content) do
        nil ->
          []

        [match | _] ->
          [Finding.warn("destructive_commands", "Destructive command detected: #{desc}", match)]
      end
    end)
    |> Enum.uniq_by(& &1.rule)
    |> List.flatten()
  end

  # ── Rule: remote_exec ────────────────────────────────────────────────────────

  @remote_exec_patterns [
    {~r/curl\s+[^|]+\|\s*(bash|sh|python\d*|ruby|perl|node)\b/i,
     "curl piped to shell interpreter (remote code execution)"},
    {~r/wget\s+[^|]+\|\s*(bash|sh|python\d*|ruby|perl|node)\b/i,
     "wget piped to shell interpreter (remote code execution)"},
    {~r/\beval\s*\$\s*[\(\`].*curl/, "eval of curl output (remote code execution)"},
    {~r/\beval\s*\$\s*[\(\`].*wget/, "eval of wget output (remote code execution)"},
    {~r/python\s+-c\s+['""].*urllib.*urlopen.*exec/i,
     "Python urllib + exec (remote code execution)"}
  ]

  defp check_remote_exec(content) do
    @remote_exec_patterns
    |> Enum.flat_map(fn {pattern, desc} ->
      case Regex.run(pattern, content) do
        nil ->
          []

        [match | _] ->
          [Finding.block("remote_exec", "Remote execution pattern: #{desc}", match)]
      end
    end)
    |> Enum.uniq_by(& &1.message)
  end

  # ── Rule: exfiltration ───────────────────────────────────────────────────────

  @sensitive_paths [
    "/etc/passwd",
    "/etc/shadow",
    "/etc/sudoers",
    "~/.ssh/",
    "~/.aws/",
    "~/.gnupg/",
    "/root/",
    "$HOME/.ssh",
    "$HOME/.aws"
  ]

  @exfil_upload_patterns [
    ~r/\bcurl\b.*--data\b/,
    ~r/\bcurl\b.*-d\s/,
    ~r/\bnc\s.*<\s*/,
    ~r/\bsocat\b/,
    ~r/\btelnet\b.*<\s*/
  ]

  defp check_exfiltration(content) do
    sensitive_hits =
      @sensitive_paths
      |> Enum.filter(&String.contains?(content, &1))
      |> Enum.flat_map(fn path ->
        # Only flag when a sensitive path appears alongside a network tool
        if content_has_network_tool?(content) do
          [
            Finding.block(
              "exfiltration",
              "Sensitive path '#{path}' referenced alongside network tool — potential data exfiltration",
              path
            )
          ]
        else
          []
        end
      end)
      |> Enum.uniq_by(& &1.match)

    upload_hits =
      @exfil_upload_patterns
      |> Enum.flat_map(fn pattern ->
        case Regex.run(pattern, content) do
          nil ->
            []

          [match | _] ->
            if content_has_sensitive_path?(content) do
              [
                Finding.block(
                  "exfiltration",
                  "Upload pattern with sensitive path access: #{match}",
                  match
                )
              ]
            else
              []
            end
        end
      end)
      |> Enum.uniq_by(& &1.match)

    sensitive_hits ++ upload_hits
  end

  @network_tool_pattern ~r/\b(curl|wget|nc|socat|telnet|https?|ftp)\b/

  defp content_has_network_tool?(content) do
    Regex.match?(@network_tool_pattern, content)
  end

  defp content_has_sensitive_path?(content) do
    Enum.any?(@sensitive_paths, &String.contains?(content, &1))
  end

  # ── Rule: path_traversal ─────────────────────────────────────────────────────

  @traversal_patterns [
    {~r/\.\.\/\.\.\//, "Directory traversal sequence (../../)"},
    {~r/\.\.\\\.\.\\/, "Windows traversal sequence (..\\..\\)"},
    {~r/\/etc\/passwd/, "Direct reference to /etc/passwd"},
    {~r/\/etc\/shadow/, "Direct reference to /etc/shadow"},
    {~r/\/etc\/sudoers/, "Direct reference to /etc/sudoers"},
    {~r/--path\s*=\s*\/etc\//i, "Option targeting /etc/"}
  ]

  defp check_path_traversal(content) do
    @traversal_patterns
    |> Enum.flat_map(fn {pattern, desc} ->
      case Regex.run(pattern, content) do
        nil ->
          []

        [match | _] ->
          [Finding.warn("path_traversal", "Path traversal pattern: #{desc}", match)]
      end
    end)
    |> Enum.uniq_by(& &1.message)
  end

  # ── Rule: symlink_escape ─────────────────────────────────────────────────────

  @symlink_patterns [
    {~r/\bln\s+-[a-zA-Z]*s[a-zA-Z]*\s+\/etc\//, :block, "Symlink to /etc/ (potential escape)"},
    {~r/\bln\s+-[a-zA-Z]*s[a-zA-Z]*\s+\/root\//, :block, "Symlink to /root/ (potential escape)"},
    {~r/\bln\s+-[a-zA-Z]*s[a-zA-Z]*\s+~\/\.ssh\//, :block,
     "Symlink to ~/.ssh/ (potential escape)"},
    {~r/\bchmod\s+\+x\b/, :warn, "chmod +x (making file executable)"},
    {~r/\bchown\s+root\b/i, :warn, "chown root (changing ownership to root)"}
  ]

  defp check_symlink_escape(content) do
    @symlink_patterns
    |> Enum.flat_map(fn {pattern, severity, desc} ->
      case Regex.run(pattern, content) do
        nil ->
          []

        [match | _] ->
          finding =
            case severity do
              :block -> Finding.block("symlink_escape", desc, match)
              :warn -> Finding.warn("symlink_escape", desc, match)
            end

          [finding]
      end
    end)
    |> Enum.uniq_by(& &1.message)
  end

  # ── Verdict aggregation ───────────────────────────────────────────────────────

  defp overall_verdict([]), do: :pass

  defp overall_verdict(findings) do
    if Enum.any?(findings, &Finding.blocks_install?/1) do
      :block
    else
      :warn
    end
  end
end
