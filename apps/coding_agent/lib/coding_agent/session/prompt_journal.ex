defmodule CodingAgent.Session.PromptJournal do
  @moduledoc """
  Branch-local system-prompt snapshots for assistant journal entries.

  The digest covers the actual ordered provider blocks, including their directory
  boundary. Resume accepts a rebuilt prompt only when that digest agrees; otherwise
  the saved blocks remain authoritative until an explicit extension reload.

  Each assistant entry's `"system-prompt-digest"` references its prompt by digest
  and plan revision (version 2). The prompt itself is written once per digest on
  a branch, as a `lemon.prompt_snapshot` custom entry appended just before the
  first reply that used it; `"base_prompt"` is kept only when a plan overlay
  makes it differ from the prompt. A reference resolves to the nearest snapshot
  with its digest among the reply's ancestors, so branch-path copies (forks)
  and full rewrites keep it. Version 1 entries from older journals embed the
  prompt inline and are still read.
  """

  alias CodingAgent.Session.{Planning, PromptComposer}
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias LemonAi.SystemPrompt

  @key "system-prompt-digest"
  @snapshot_type "lemon.prompt_snapshot"

  @doc "Provider blocks for the current prompt, preserving a resumed snapshot verbatim."
  def blocks(state, prompt \\ nil) do
    prompt = prompt || Map.get(state, :system_prompt) || ""
    saved = Map.get(state, :journaled_prompt)

    if saved && SystemPrompt.text(saved.blocks) == prompt,
      do: saved.blocks,
      else: PromptComposer.prompt_blocks(prompt, Map.get(state, :prompt_sections) || [])
  end

  @doc "Keep a resumed prompt byte-identical unless the journal's plan mode changes."
  def planning_prompt(state) do
    saved = Map.get(state, :journaled_prompt)

    if saved && saved.plan_revision == plan_revision(state.session_manager),
      do: SystemPrompt.text(saved.blocks),
      else:
        Planning.system_prompt(
          state.base_system_prompt || state.system_prompt || "",
          state.session_manager
        )
  end

  defp plan_revision(session) do
    case SessionManager.latest_custom_entry(session, "lemon.plan") do
      nil -> nil
      entry -> entry.id
    end
  end

  @doc """
  Append an assistant reply with a reference to the exact response prompt.

  The prompt is journaled first, as a `lemon.prompt_snapshot` entry, only when
  no ancestor on the selected branch already holds that digest.
  """
  def append_reply(%SessionManager.Session{} = session, message, state) do
    prompt =
      case Map.get(state, :response_system_prompt) || blocks(state) do
        text when is_binary(text) -> [%{text: text, directory_derived: false}]
        blocks -> blocks
      end

    digest = SystemPrompt.digest(prompt)

    session =
      if snapshot_entry(session.by_id, session.leaf_id, digest) do
        session
      else
        text = SystemPrompt.text(prompt)
        overlay = Planning.system_prompt("", session)
        base = base_prompt(text, overlay, Map.get(state, :base_system_prompt))
        data = %{"digest" => digest, "prompt" => prompt}
        data = if base == text, do: data, else: Map.put(data, "base_prompt", base)
        SessionManager.append_entry(session, SessionEntry.custom(@snapshot_type, data))
      end

    SessionManager.append_message(
      session,
      Map.put(message, @key, %{
        "version" => 2,
        "digest" => digest,
        "plan_revision" => plan_revision(session)
      })
    )
  end

  defp base_prompt(text, "", _base), do: text

  defp base_prompt(text, overlay, base) when is_binary(base) do
    prefix = base <> overlay

    if String.starts_with?(text, prefix),
      do: base <> binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix)),
      else: String.replace_suffix(text, overlay, "")
  end

  defp base_prompt(text, overlay, _base), do: String.replace_suffix(text, overlay, "")

  @doc "Select the rebuilt or journaled prompt for startup and branch restoration."
  def restore(session, base, sections) do
    prompt = Planning.system_prompt(base, session)
    rebuilt = PromptComposer.prompt_blocks(prompt, sections)

    case latest(session) do
      %{digest: digest} = saved ->
        if digest == SystemPrompt.digest(rebuilt) do
          attributes(prompt, base, sections, nil)
        else
          attributes(SystemPrompt.text(saved.prompt), saved.base_prompt, [], %{
            blocks: saved.prompt,
            plan_revision: saved.plan_revision
          })
        end

      nil ->
        attributes(prompt, base, sections, nil)
    end
  end

  defp attributes(prompt, base, sections, journaled) do
    %{
      system_prompt: prompt,
      base_system_prompt: base,
      prompt_sections: sections,
      journaled_prompt: journaled,
      response_system_prompt: nil
    }
  end

  @doc "Restore prompt identity from the selected branch without changing messages."
  def restore_state(state) do
    attributes =
      restore(state.session_manager, state.base_system_prompt, state.prompt_sections || [])

    state = Map.merge(state, attributes)
    :ok = LemonAgent.Agent.set_system_prompt(state.agent, blocks(state))
    state
  end

  @doc "The latest assistant's snapshot on the active branch; legacy replies return nil."
  def latest(%SessionManager.Session{} = session) do
    case latest_reply(session.by_id, session.leaf_id) do
      nil -> nil
      entry -> decode(entry, session.by_id)
    end
  end

  def latest(_), do: nil

  defp latest_reply(_entries, nil), do: nil

  defp latest_reply(entries, id) do
    case Map.get(entries, id) do
      %{type: :message, message: %{"role" => "assistant"}} = entry -> entry
      %{parent_id: parent} -> latest_reply(entries, parent)
      nil -> nil
    end
  end

  defp snapshot_entry(_entries, nil, _digest), do: nil

  defp snapshot_entry(entries, id, digest) do
    case Map.get(entries, id) do
      %{type: :custom, custom_type: @snapshot_type, data: %{"digest" => ^digest}} = entry ->
        entry

      %{parent_id: parent} ->
        snapshot_entry(entries, parent, digest)

      nil ->
        nil
    end
  end

  defp decode(%{message: message} = entry, entries) do
    case message[@key] do
      nil ->
        nil

      %{"version" => 2, "digest" => digest, "plan_revision" => plan_revision}
      when is_binary(digest) and (is_binary(plan_revision) or is_nil(plan_revision)) ->
        case snapshot_entry(entries, entry.parent_id, digest) do
          %{data: %{"prompt" => prompt} = data} ->
            decode_prompt(digest, prompt, Map.get(data, "base_prompt"), plan_revision)

          nil ->
            raise ArgumentError, "journaled system prompt snapshot is missing"
        end

      # Journals written before snapshots were shared embed the prompt inline.
      %{
        "version" => 1,
        "digest" => digest,
        "prompt" => prompt,
        "base_prompt" => base,
        "plan_revision" => plan_revision
      }
      when is_binary(digest) and is_binary(base) and
             (is_binary(plan_revision) or is_nil(plan_revision)) ->
        decode_prompt(digest, prompt, base, plan_revision)

      _ ->
        raise ArgumentError, "invalid journaled system prompt snapshot"
    end
  end

  defp decode_prompt(digest, prompt, base, plan_revision)
       when is_list(prompt) and (is_binary(base) or is_nil(base)) do
    blocks =
      Enum.map(prompt, fn
        %{text: text, directory_derived: directory}
        when is_binary(text) and is_boolean(directory) ->
          %{text: text, directory_derived: directory}

        %{"text" => text, "directory_derived" => directory}
        when is_binary(text) and is_boolean(directory) ->
          %{text: text, directory_derived: directory}

        _ ->
          raise ArgumentError, "invalid journaled system prompt block"
      end)

    if SystemPrompt.digest(blocks) != digest,
      do: raise(ArgumentError, "journaled system prompt digest does not match its blocks")

    %{
      digest: digest,
      prompt: blocks,
      base_prompt: base || SystemPrompt.text(blocks),
      plan_revision: plan_revision
    }
  end

  defp decode_prompt(_digest, _prompt, _base, _plan_revision),
    do: raise(ArgumentError, "invalid journaled system prompt snapshot")

  @doc "Content-free cache diagnostics for live and durable context reports."
  def cache_report(session, current \\ nil, restored \\ false) do
    {latest, previous} = recent_snapshots(session)
    digest = if is_nil(current), do: latest && latest.digest, else: SystemPrompt.digest(current)

    previous_digest =
      if latest && digest != latest.digest,
        do: latest.digest,
        else: previous && previous.digest

    {status, explanation} =
      cond do
        restored ->
          {:restored, "Rebuilt system prompt digest changed; the journaled prompt was retained."}

        digest && previous_digest && digest != previous_digest ->
          {:digest_changed,
           "System prompt digest changed; changed prompt bytes or cache boundaries can cause a cache miss."}

        digest && previous_digest ->
          {:unchanged,
           "System prompt digest is unchanged; cache misses can still depend on provider, expiry or other request content."}

        true ->
          {:unknown, "No previous system prompt digest is available for comparison."}
      end

    %{
      digest: digest,
      previous_digest: previous_digest,
      status: status,
      explanation: explanation
    }
  end

  defp recent_snapshots(%SessionManager.Session{} = session) do
    case latest_reply(session.by_id, session.leaf_id) do
      nil ->
        {nil, nil}

      entry ->
        previous = latest_reply(session.by_id, entry.parent_id)
        {decode(entry, session.by_id), if(previous, do: decode(previous, session.by_id))}
    end
  end

  defp recent_snapshots(_), do: {nil, nil}
end
