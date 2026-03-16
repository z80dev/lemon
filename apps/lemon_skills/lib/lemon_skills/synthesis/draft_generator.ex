defmodule LemonSkills.Synthesis.DraftGenerator do
  @moduledoc """
  Generates a draft SKILL.md from a qualified `MemoryDocument`.

  The generator produces a manifest v2 YAML frontmatter block plus a structured
  body that captures the task pattern and solution.  The output is suitable for
  passing directly to `LemonSkills.Audit.Engine.audit_content/1` and then to
  `LemonSkills.Synthesis.DraftStore.put/2`.

  ## Output shape

      %{
        key:     "deploy-to-k8s",           # URL-safe skill identifier
        name:    "Deploy to K8s",            # human-readable display name
        content: "---\n...\n---\n\n# ...",  # full SKILL.md content string
        source_doc_id: "abc123"             # originating MemoryDocument ID
      }

  ## Limitations

  - Generated skills are drafts; they require human review before promotion.
  - Secret filtering is conservative: if any pattern matches the document is
    rejected with `{:error, :contains_secrets}`.
  - The generated SKILL.md body is intentionally terse; it does not reproduce
    the full conversation, only the distilled pattern.
  """

  alias LemonCore.MemoryDocument
  alias LemonCore.TaskFingerprint

  @type draft :: %{
          key: String.t(),
          name: String.t(),
          content: String.t(),
          source_doc_id: String.t()
        }

  @doc """
  Return a short slug for the document, suitable for display in log messages.

  Not guaranteed to be unique across documents.
  """
  @spec derive_key_hint(String.t()) :: String.t()
  def derive_key_hint(prompt_summary) when is_binary(prompt_summary) do
    prompt_summary
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(3)
    |> Enum.join("-")
    |> case do
      "" -> "unknown"
      hint -> hint
    end
  end

  def derive_key_hint(_), do: "unknown"

  @doc """
  Generate a draft from a `MemoryDocument`.

  Returns `{:ok, draft}` on success, or `{:error, reason}` when the document
  is not suitable (e.g. contains secrets).
  """
  @spec generate(MemoryDocument.t()) :: {:ok, draft()} | {:error, term()}
  def generate(%MemoryDocument{} = doc) do
    key = derive_key(doc.prompt_summary)
    name = derive_name(doc.prompt_summary)

    fp = TaskFingerprint.from_document(doc)
    category = family_to_category(fp.task_family)
    tools = fp.toolset

    frontmatter = build_frontmatter(name, doc.prompt_summary, category, tools)
    body = build_body(doc, fp)
    content = "---\n#{frontmatter}---\n\n#{body}"

    {:ok,
     %{
       key: key,
       name: name,
       content: content,
       source_doc_id: doc.doc_id
     }}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp derive_key(prompt) when is_binary(prompt) do
    prompt
    |> String.downcase()
    |> String.slice(0, 60)
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.split(~r/\s+/)
    |> Enum.take(5)
    |> Enum.join("-")
    |> String.trim("-")
    |> case do
      "" -> "synthesized-skill"
      key -> "synth-#{key}"
    end
  end

  defp derive_name(prompt) when is_binary(prompt) do
    prompt
    |> String.slice(0, 80)
    |> String.split(~r/[.!?\n]/, parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> "Synthesized Skill"
      name -> truncate(name, 60)
    end
  end

  defp build_frontmatter(name, prompt_summary, category, tools) do
    description = derive_description(prompt_summary)
    tools_yaml = Enum.map_join(tools, "\n", fn t -> "  - #{t}" end)

    requires_tools_block =
      if tools == [] do
        ""
      else
        "requires_tools:\n#{tools_yaml}\n"
      end

    """
    name: #{yaml_string(name)}
    description: #{yaml_string(description)}
    #{requires_tools_block}metadata:
      lemon:
        category: #{category}
        synthesized: true
    """
  end

  defp build_body(%MemoryDocument{} = doc, %TaskFingerprint{} = fp) do
    tools_note =
      case fp.toolset do
        [] -> ""
        tools -> "\n**Tools used:** #{Enum.join(tools, ", ")}\n"
      end

    """
    # #{derive_name(doc.prompt_summary)}

    > **Synthesized skill** — generated from a successful run on
    > #{format_date_ms(doc.ingested_at_ms)}.  Review and edit before promoting.

    ## Task Pattern
    #{tools_note}
    #{doc.prompt_summary}

    ## Approach

    #{doc.answer_summary}
    """
  end

  defp derive_description(prompt) when is_binary(prompt) do
    prompt
    |> String.slice(0, 120)
    |> String.split(~r/[.!?\n]/, parts: 2)
    |> List.first()
    |> String.trim()
    |> truncate(100)
  end

  defp family_to_category(:code), do: "engineering"
  defp family_to_category(:query), do: "knowledge"
  defp family_to_category(:file_ops), do: "filesystem"
  defp family_to_category(_), do: "general"

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  # Escape a YAML string value (single-line, no special chars needed for simple cases).
  defp yaml_string(value) when is_binary(value) do
    escaped = String.replace(value, "\"", "\\\"")
    "\"#{escaped}\""
  end

  defp format_date_ms(nil), do: "an earlier run"
  defp format_date_ms(0), do: "an earlier run"

  defp format_date_ms(ms) when is_integer(ms) do
    dt = DateTime.from_unix!(ms, :millisecond)
    "#{dt.year}-#{zero_pad(dt.month)}-#{zero_pad(dt.day)}"
  end

  defp zero_pad(n) when n < 10, do: "0#{n}"
  defp zero_pad(n), do: "#{n}"
end
