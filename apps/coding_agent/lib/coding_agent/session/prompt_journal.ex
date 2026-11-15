defmodule CodingAgent.Session.PromptJournal do
  @moduledoc """
  Branch-local system-prompt snapshots, embedded in each assistant journal entry.

  The digest covers the actual ordered provider blocks, including their directory
  boundary. Resume accepts a rebuilt prompt only when that digest agrees; otherwise
  the saved blocks remain authoritative until an explicit extension reload.
  """

  alias CodingAgent.Session.{Planning, PromptComposer}
  alias CodingAgent.SessionManager
  alias LemonAi.SystemPrompt

  @key "system-prompt-digest"

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

  @doc "Attach the exact response prompt to the same atomic append as its reply."
  def attach(message, state) do
    prompt =
      case Map.get(state, :response_system_prompt) || blocks(state) do
        text when is_binary(text) -> [%{text: text, directory_derived: false}]
        blocks -> blocks
      end

    text = SystemPrompt.text(prompt)
    overlay = Planning.system_prompt("", state.session_manager)
    base = base_prompt(text, overlay, Map.get(state, :base_system_prompt))

    Map.put(message, @key, %{
      "version" => 1,
      "digest" => SystemPrompt.digest(prompt),
      "prompt" => prompt,
      "base_prompt" => base,
      "plan_revision" => plan_revision(state.session_manager)
    })
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
      entry -> decode(entry.message[@key])
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

  defp decode(nil), do: nil

  defp decode(%{
         "version" => 1,
         "digest" => digest,
         "prompt" => prompt,
         "base_prompt" => base,
         "plan_revision" => plan_revision
       })
       when is_binary(digest) and is_list(prompt) and is_binary(base) and
              (is_binary(plan_revision) or is_nil(plan_revision)) do
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

    %{digest: digest, prompt: blocks, base_prompt: base, plan_revision: plan_revision}
  end

  defp decode(_), do: raise(ArgumentError, "invalid journaled system prompt snapshot")

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
        {decode(entry.message[@key]), if(previous, do: decode(previous.message[@key]))}
    end
  end

  defp recent_snapshots(_), do: {nil, nil}
end
