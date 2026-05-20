defmodule LemonRouter.SubmissionBuilder do
  @moduledoc """
  Builds the router-owned submission handed from orchestration to coordination.

  This module resolves profile/session defaults, sticky engine state, resume
  behavior, and conversation selection before constructing the canonical
  `%LemonCore.ExecutionCommand{}` and wrapping it in `%LemonRouter.Submission{}`.
  """

  require Logger

  alias LemonCore.{
    Cwd,
    ExecutionCommand,
    MapHelpers,
    RoutingFeedbackStore,
    RunRequest,
    SessionKey,
    TaskFingerprint
  }

  alias LemonRouter.{
    AgentProfiles,
    ConversationKey,
    ModelSelection,
    Policy,
    ResumeResolver,
    StickyEngine,
    Submission
  }

  @thinking_levels %{
    "off" => :off,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }

  @pending_compaction_ttl_ms 12 * 60 * 60 * 1000

  @spec build(RunRequest.t(), map()) :: {:ok, Submission.t()} | {:error, term()}
  def build(%RunRequest{} = params, opts) when is_map(opts) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    prompt = params.prompt
    images = params.images || []
    queue_mode = params.queue_mode || :collect
    engine_id = params.engine_id
    request_model = params.model
    meta = params.meta || %{}
    cwd_override = params.cwd
    tool_policy_override = params.tool_policy
    run_id = params.run_id

    session_config = get_session_config(session_key)

    with {:ok, agent_profile} <- get_agent_profile(agent_id) do
      base_tool_policy =
        Policy.resolve_for_run(%{
          agent_id: agent_id,
          session_key: session_key,
          origin: origin,
          channel_context: MapHelpers.get_key(meta, :channel_context)
        })

      profile_tool_policy = normalize_profile_tool_policy(agent_profile)

      base_tool_policy =
        if is_map(profile_tool_policy) and map_size(profile_tool_policy) > 0 do
          Policy.merge(base_tool_policy, profile_tool_policy)
        else
          base_tool_policy
        end

      tool_policy =
        if tool_policy_override && is_map(tool_policy_override) do
          Policy.merge(base_tool_policy, tool_policy_override)
        else
          base_tool_policy
        end

      cwd = resolve_effective_cwd(cwd_override, meta)
      prompt = maybe_apply_pending_compaction(prompt, session_key, origin)

      prompt =
        if MapHelpers.get_key(meta, :voice_transcribed) do
          "(voice transcribed) " <> (prompt || "")
        else
          prompt
        end

      session_model = MapHelpers.get_key(session_config, :model)
      session_thinking_level = MapHelpers.get_key(session_config, :thinking_level)
      request_thinking_level = MapHelpers.get_key(meta, :thinking_level)
      session_preferred_engine = MapHelpers.get_key(session_config, :preferred_engine)

      profile_model = MapHelpers.get_key(agent_profile, :model)
      profile_default_engine = MapHelpers.get_key(agent_profile, :default_engine)
      profile_system_prompt = MapHelpers.get_key(agent_profile, :system_prompt)
      default_model = default_model_from_config()

      explicit_model = request_model || MapHelpers.get_key(meta, :model)
      explicit_system_prompt = MapHelpers.get_key(meta, :system_prompt)

      {sticky_engine_id, sticky_session_updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: engine_id,
          prompt: prompt,
          session_preferred_engine: session_preferred_engine
        })

      persist_sticky_engine(session_key, sticky_session_updates)

      effective_engine_id = engine_id || sticky_engine_id
      history_model = resolve_history_model(prompt, cwd, explicit_model, meta)

      selection =
        ModelSelection.resolve(%{
          explicit_model: explicit_model,
          meta_model: MapHelpers.get_key(meta, :model),
          session_model: session_model,
          profile_model: profile_model,
          history_model: history_model,
          default_model: default_model,
          explicit_engine_id: effective_engine_id,
          profile_default_engine: profile_default_engine,
          resume_engine: params.resume && params.resume.engine
        })

      resolved_model = selection.model

      resolved_thinking_level =
        normalize_thinking_level(request_thinking_level || session_thinking_level)

      resolved_system_prompt = explicit_system_prompt || profile_system_prompt

      if is_binary(selection.warning) do
        Logger.warning(
          "Model/engine mismatch for run_id=#{inspect(run_id)}: #{selection.warning}"
        )
      end

      {resolved_resume, resolved_engine_id} =
        ResumeResolver.resolve(params.resume, session_key, selection.engine_id, meta)

      conversation_key = ConversationKey.resolve(session_key, resolved_resume)

      enriched_meta =
        meta
        |> Map.merge(%{
          origin: origin,
          agent_id: agent_id,
          thinking_level: resolved_thinking_level,
          model: resolved_model
        })
        |> maybe_put(:model_resolution_warning, selection.warning)
        |> maybe_put(:system_prompt, resolved_system_prompt)
        |> maybe_put(:routing_feedback_model, history_model)

      execution_request = %ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        engine_id: resolved_engine_id,
        images: images,
        cwd: cwd,
        resume: resolved_resume,
        lane: MapHelpers.get_key(meta, :lane) || :main,
        tool_policy: tool_policy,
        meta: enriched_meta,
        conversation_key: conversation_key
      }

      {:ok,
       Submission.new!(%{
         run_id: run_id,
         session_key: session_key,
         conversation_key: conversation_key,
         queue_mode: queue_mode,
         execution_request: execution_request,
         run_supervisor: MapHelpers.get_key(opts, :run_supervisor),
         run_process_module: MapHelpers.get_key(opts, :run_process_module),
         run_process_opts: MapHelpers.get_key(opts, :run_process_opts),
         meta: enriched_meta
       })}
    end
  end

  def build(_request, _opts), do: {:error, :invalid_run_request}

  defp persist_sticky_engine(nil, _updates), do: :ok
  defp persist_sticky_engine(_session_key, updates) when map_size(updates) == 0, do: :ok

  defp persist_sticky_engine(session_key, updates) do
    existing = LemonCore.PolicyStore.get_session(session_key) || %{}
    updated = Map.merge(existing, updates)
    LemonCore.PolicyStore.put_session(session_key, updated)
  rescue
    error ->
      Logger.warning(
        "Failed to persist sticky engine for session=#{inspect(session_key)}: #{Exception.message(error)}"
      )
  end

  defp get_session_config(nil), do: %{}

  defp get_session_config(session_key) do
    case LemonCore.PolicyStore.get_session(session_key) do
      nil -> %{}
      config when is_map(config) -> config
    end
  rescue
    _ -> %{}
  end

  defp get_agent_profile(agent_id) when is_binary(agent_id) do
    if agent_profile_exists?(agent_id) do
      case AgentProfiles.get(agent_id) do
        profile when is_map(profile) -> {:ok, profile}
        _ -> {:ok, %{}}
      end
    else
      {:error, {:unknown_agent_id, agent_id}}
    end
  rescue
    _ ->
      if fallback_agent_profile_exists?(agent_id) do
        {:ok, %{}}
      else
        {:error, {:unknown_agent_id, agent_id}}
      end
  catch
    :exit, _ ->
      if fallback_agent_profile_exists?(agent_id) do
        {:ok, %{}}
      else
        {:error, {:unknown_agent_id, agent_id}}
      end
  end

  defp get_agent_profile(_), do: {:error, {:unknown_agent_id, nil}}

  defp agent_profile_exists?(agent_id) when is_binary(agent_id) and agent_id != "" do
    AgentProfiles.exists?(agent_id) == true
  rescue
    _ -> fallback_agent_profile_exists?(agent_id)
  catch
    :exit, _ -> fallback_agent_profile_exists?(agent_id)
  end

  defp agent_profile_exists?(_), do: false

  defp fallback_agent_profile_exists?(agent_id) when is_binary(agent_id) and agent_id != "" do
    cfg = LemonCore.Config.cached()
    agents = MapHelpers.get_key(cfg, :agents) || %{}
    Map.has_key?(agents, agent_id) or agent_id == "default"
  rescue
    _ -> agent_id == "default"
  catch
    :exit, _ -> agent_id == "default"
  end

  defp fallback_agent_profile_exists?(_), do: false

  defp normalize_profile_tool_policy(profile) when is_map(profile) do
    case MapHelpers.get_key(profile, :tool_policy) do
      policy when is_map(policy) -> policy
      _ -> %{}
    end
  end

  defp normalize_profile_tool_policy(_), do: %{}

  defp resolve_effective_cwd(cwd_override, meta) do
    normalize_cwd(cwd_override) || normalize_cwd(MapHelpers.get_key(meta, :cwd)) ||
      Cwd.default_cwd()
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

  defp default_model_from_config do
    LemonCore.Config.cached().agent.default_model
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_apply_pending_compaction(prompt, session_key, :channel)
       when is_binary(session_key) do
    case LemonRouter.PendingCompactionStore.get(session_key) do
      pending when is_map(pending) ->
        if pending_compaction_fresh?(pending) do
          apply_pending_compaction(prompt, session_key)
        else
          _ = LemonRouter.PendingCompactionStore.delete(session_key)

          Logger.debug(
            "Router cleared stale pending compaction session_key=#{inspect(session_key)}"
          )

          prompt
        end

      _ ->
        prompt
    end
  rescue
    _ -> prompt
  end

  defp maybe_apply_pending_compaction(prompt, _session_key, _origin), do: prompt

  defp apply_pending_compaction(prompt, session_key) do
    transcript =
      LemonCore.RunStore.history(session_key, limit: 8)
      |> format_run_history_transcript(max_chars: 8_000)

    if transcript != "" do
      _ = LemonRouter.PendingCompactionStore.delete(session_key)

      Logger.warning(
        "Router applying pending compaction session_key=#{inspect(session_key)} " <>
          "transcript_chars=#{byte_size(transcript)}"
      )

      build_pending_compaction_prompt(transcript, prompt || "")
    else
      _ = LemonRouter.PendingCompactionStore.delete(session_key)
      prompt
    end
  rescue
    _ -> prompt
  end

  defp pending_compaction_fresh?(pending) when is_map(pending) do
    set_at_ms = pending[:set_at_ms] || pending["set_at_ms"]

    cond do
      is_integer(set_at_ms) ->
        System.system_time(:millisecond) - set_at_ms <= @pending_compaction_ttl_ms

      true ->
        true
    end
  rescue
    _ -> false
  end

  defp pending_compaction_fresh?(_), do: false

  defp build_pending_compaction_prompt(transcript, user_text)
       when is_binary(transcript) and is_binary(user_text) do
    user_text = String.trim(user_text)

    base =
      [
        "The previous conversation reached the model context limit.",
        "Use this compact transcript as prior context and continue.",
        "",
        "<previous_conversation>",
        transcript,
        "</previous_conversation>"
      ]
      |> Enum.join("\n")

    if user_text == "" do
      String.trim(base <> "\n\nContinue.")
    else
      String.trim(base <> "\n\nUser:\n" <> user_text)
    end
  end

  defp build_pending_compaction_prompt(_transcript, user_text), do: user_text

  defp format_run_history_transcript(history, opts) when is_list(history) do
    max_chars = Keyword.get(opts, :max_chars, 12_000)

    text =
      history
      |> Enum.reverse()
      |> Enum.map(&format_run_history_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.trim()

    if String.length(text) > max_chars do
      String.slice(text, String.length(text) - max_chars, max_chars)
    else
      text
    end
  rescue
    _ -> ""
  end

  defp format_run_history_transcript(_other, _opts), do: ""

  defp format_run_history_entry({_run_id, data}) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    prompt = summary[:prompt] || summary["prompt"] || ""
    answer = summary[:answer] || summary["answer"] || ""

    []
    |> maybe_append("User: " <> String.trim(prompt), prompt)
    |> maybe_append("Assistant: " <> String.trim(answer), answer)
    |> Enum.join("\n")
  end

  defp format_run_history_entry(_), do: ""

  defp maybe_append(parts, text, raw) do
    if is_binary(raw) and String.trim(raw) != "" do
      parts ++ [text]
    else
      parts
    end
  end

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(level) when is_atom(level), do: level
  defp normalize_thinking_level(level) when is_binary(level), do: Map.get(@thinking_levels, level)
  defp normalize_thinking_level(_), do: nil

  defp resolve_history_model(prompt, cwd, explicit_model, _meta)
       when is_binary(explicit_model) and byte_size(explicit_model) > 0 do
    _ = {prompt, cwd}
    nil
  end

  defp resolve_history_model(prompt, cwd, _explicit_model, _meta) do
    try do
      config = LemonCore.Config.Modular.load()

      if LemonCore.Config.Features.enabled?(config.features, :routing_feedback) do
        fp = %TaskFingerprint{
          task_family: TaskFingerprint.classify_prompt(prompt),
          workspace_key: cwd
        }

        context_key = TaskFingerprint.context_key(fp)

        case RoutingFeedbackStore.best_model_for_context(context_key) do
          {:ok, model} -> model
          _ -> nil
        end
      else
        nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
