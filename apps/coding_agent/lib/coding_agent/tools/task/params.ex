defmodule CodingAgent.Tools.Task.Params do
  @moduledoc false

  require Logger

  alias AgentCore.Types.AgentTool
  alias CodingAgent.BudgetEnforcer
  alias CodingAgent.Subagents
  alias CodingAgent.ToolPolicy
  alias LemonCore.SessionKey

  @valid_queue_modes ["collect", "followup", "steer", "steer_backlog", "interrupt"]
  @valid_engines ["internal", "codex", "claude", "kimi", "opencode", "pi"]

  @spec valid_queue_modes() :: [String.t()]
  def valid_queue_modes, do: @valid_queue_modes

  @spec normalize_optional_string(term()) :: term()
  def normalize_optional_string(nil), do: nil

  def normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_optional_string(value), do: value

  @spec normalize_action(term()) :: String.t()
  def normalize_action(nil), do: "run"

  def normalize_action(action) when is_binary(action) do
    action |> String.trim() |> String.downcase()
  end

  def normalize_action(_), do: "run"

  @spec validate_run_params(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def validate_run_params(params, cwd) do
    description = Map.get(params, "description")
    prompt = Map.get(params, "prompt")
    role_id = normalize_optional_string(Map.get(params, "role"))
    engine = Map.get(params, "engine")
    model = normalize_optional_string(Map.get(params, "model"))
    thinking_level = normalize_optional_string(Map.get(params, "thinking_level"))
    async? = Map.get(params, "async", false)
    auto_followup = Map.get(params, "auto_followup", true)
    delegated_cwd = normalize_optional_string(Map.get(params, "cwd"))
    tool_policy = Map.get(params, "tool_policy")
    meta = Map.get(params, "meta")
    session_key = normalize_optional_string(Map.get(params, "session_key"))
    agent_id = normalize_optional_string(Map.get(params, "agent_id"))
    queue_mode = Map.get(params, "queue_mode", "followup")
    role_cwd = delegated_cwd || cwd

    cond do
      not Map.has_key?(params, "description") ->
        {:error, "Description is required"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "Description must be a non-empty string"}

      not Map.has_key?(params, "prompt") ->
        {:error, "Prompt is required"}

      is_nil(prompt) ->
        {:error, "Prompt must be a non-empty string"}

      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "Prompt must be a non-empty string"}

      not is_nil(role_id) and not is_binary(role_id) ->
        {:error, "Role must be a string"}

      not is_nil(engine) and not is_binary(engine) ->
        {:error, "Engine must be a string"}

      not is_nil(engine) and engine not in @valid_engines ->
        {:error, "Engine must be one of: #{Enum.join(@valid_engines, ", ")}"}

      not is_nil(model) and not is_binary(model) ->
        {:error, "Model must be a string"}

      not is_nil(thinking_level) and not is_binary(thinking_level) ->
        {:error, "thinking_level must be a string"}

      not is_nil(delegated_cwd) and not is_binary(delegated_cwd) ->
        {:error, "cwd must be a string"}

      not is_nil(tool_policy) and not is_map(tool_policy) ->
        {:error, "tool_policy must be an object"}

      not is_nil(meta) and not is_map(meta) ->
        {:error, "meta must be an object"}

      not is_nil(session_key) and not SessionKey.valid?(session_key) ->
        {:error, "session_key must be a valid Lemon session key"}

      not is_nil(agent_id) and not is_binary(agent_id) ->
        {:error, "agent_id must be a string"}

      not is_binary(queue_mode) ->
        {:error, "queue_mode must be one of: #{Enum.join(@valid_queue_modes, ", ")}"}

      queue_mode not in @valid_queue_modes ->
        {:error, "queue_mode must be one of: #{Enum.join(@valid_queue_modes, ", ")}"}

      not is_nil(role_id) and Subagents.get(role_cwd, role_id) == nil ->
        {:error, "Unknown role: #{role_id}"}

      not is_boolean(async?) ->
        {:error, "Async must be a boolean"}

      not is_boolean(auto_followup) ->
        {:error, "auto_followup must be a boolean"}

      true ->
        normalized_engine = if engine == "internal", do: nil, else: engine

        {:ok,
         %{
           description: description,
           prompt: prompt,
           role_id: role_id,
           engine: normalized_engine,
           model: model,
           thinking_level: thinking_level,
           async: async?,
           auto_followup: auto_followup,
           cwd: delegated_cwd,
           tool_policy: tool_policy,
           meta: meta || %{},
           session_key: session_key,
           agent_id: agent_id,
           queue_mode: normalize_queue_mode(queue_mode)
         }}
    end
  end

  @spec check_budget_and_policy(map(), keyword()) :: :ok | {:error, String.t()}
  def check_budget_and_policy(validated, opts) do
    parent_run_id = Keyword.get(opts, :parent_run_id)
    engine = validated.engine || "internal"
    effective_opts = maybe_put_kw(opts, :tool_policy, validated.tool_policy)

    budget_check =
      if parent_run_id do
        BudgetEnforcer.check_subagent_spawn(parent_run_id, effective_opts)
      else
        :ok
      end

    case budget_check do
      {:error, :budget_exceeded, details} ->
        {_action, message} =
          BudgetEnforcer.handle_budget_exceeded(parent_run_id || "unknown", details)

        {:error, message}

      _ ->
        policy = ToolPolicy.subagent_policy(String.to_atom(engine), effective_opts)

        if ToolPolicy.no_reply?(policy) do
          Logger.debug("Subagent #{engine} running in NO_REPLY mode")
        end

        :ok
    end
  end

  @spec build_description(String.t()) :: String.t()
  def build_description(cwd) do
    base =
      "Run a focused subtask. **Use async=true by default** to avoid blocking the user conversation.\n\n" <>
        "**When to use task vs agent tool:**\n" <>
        "- task: For coding work within this session's context (same project, files, tools)\n" <>
        "- agent: For delegating to a different agent profile or for cross-agent workflows\n\n" <>
        "**Async-first pattern (recommended):**\n" <>
        "1. Launch with async=true -> get task_id immediately\n" <>
        "2. Continue the user conversation without waiting\n" <>
        "3. Poll with action=poll and task_id to check status, OR\n" <>
        "4. Use action=join with multiple task_ids to wait for completion\n\n" <>
        "**Parameters:**\n" <>
        "- action: run (default), poll, or join\n" <>
        "- async: true (recommended) = non-blocking, false = wait for completion\n" <>
        "- task_id: required when action=poll\n" <>
        "- task_ids: required when action=join\n" <>
        "- mode: join mode for action=join (wait_all or wait_any)\n" <>
        "- engine: Which executor runs the task\n" <>
        "  - \"internal\" (default): Lemon's built-in agent\n" <>
        "  - \"codex\": OpenAI Codex CLI\n" <>
        "  - \"claude\": Claude Code CLI\n" <>
        "  - \"kimi\": Kimi CLI\n" <>
        "  - \"opencode\": Opencode CLI\n" <>
        "  - \"pi\": Pi (pi-coding-agent) CLI\n" <>
        "- model: Optional model override (e.g., \"gemini-2.5-pro\" for complex tasks)\n" <>
        "- thinking_level: Optional thinking level override for internal engine\n" <>
        "- role: Optional specialization that applies to ANY engine\n" <>
        "- cwd: Optional working directory override\n" <>
        "- tool_policy: Optional task-specific tool policy override\n" <>
        "- session_key/agent_id: Optional async followup routing overrides\n" <>
        "- queue_mode: Optional async followup router queue mode (default: followup)\n" <>
        "- meta: Optional metadata attached to task lifecycle/followups\n\n" <>
        "**Boundary with agent tool:**\n" <>
        "- task supports local/CLI execution controls plus followup routing overrides\n" <>
        "- agent remains the tool for router-level delegation continuity semantics\n\n" <>
        "The role prepends a system prompt to focus the executor on a specific type of work. " <>
        "You can combine any engine with any role."

    roles = Subagents.format_for_description(cwd)

    if roles == "" do
      base
    else
      base <> "\n\nAvailable roles:\n" <> roles
    end
  end

  @spec build_role_enum(String.t()) :: [String.t()] | nil
  def build_role_enum(cwd) do
    ids = Subagents.list(cwd) |> Enum.map(& &1.id)
    if ids == [], do: nil, else: ids
  end

  @spec maybe_add_enum(AgentTool.t(), [String.t()] | nil) :: AgentTool.t()
  def maybe_add_enum(%AgentTool{} = tool, nil), do: tool

  def maybe_add_enum(%AgentTool{} = tool, enum) do
    params = tool.parameters
    props = params["properties"] || %{}
    role = Map.get(props, "role", %{})
    role = Map.put(role, "enum", enum)
    props = Map.put(props, "role", role)
    %{tool | parameters: Map.put(params, "properties", props)}
  end

  @spec build_session_opts(String.t(), keyword(), map()) :: keyword()
  def build_session_opts(cwd, opts, validated) do
    base_opts =
      opts
      |> Keyword.take([
        :model,
        :thinking_level,
        :system_prompt,
        :prompt_template,
        :workspace_dir,
        :get_api_key,
        :stream_fn,
        :stream_options,
        :settings_manager,
        :ui_context,
        :parent_session,
        :tool_policy,
        :session_key,
        :agent_id
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    override_opts =
      []
      |> maybe_put_kw(:model, validated[:model])
      |> maybe_put_kw(:thinking_level, validated[:thinking_level])
      |> maybe_put_kw(:tool_policy, validated[:tool_policy])
      |> maybe_put_kw(:session_key, validated[:session_key])
      |> maybe_put_kw(:agent_id, validated[:agent_id])

    [{:cwd, cwd}, {:register, true} | Keyword.merge(base_opts, override_opts)]
  end

  @spec normalize_queue_mode(term()) :: :collect | :followup | :steer | :steer_backlog | :interrupt
  def normalize_queue_mode("collect"), do: :collect
  def normalize_queue_mode("followup"), do: :followup
  def normalize_queue_mode("steer"), do: :steer
  def normalize_queue_mode("steer_backlog"), do: :steer_backlog
  def normalize_queue_mode("interrupt"), do: :interrupt
  def normalize_queue_mode(:collect), do: :collect
  def normalize_queue_mode(:followup), do: :followup
  def normalize_queue_mode(:steer), do: :steer
  def normalize_queue_mode(:steer_backlog), do: :steer_backlog
  def normalize_queue_mode(:interrupt), do: :interrupt
  def normalize_queue_mode(_), do: :followup

  defp maybe_put_kw(list, _key, nil), do: list
  defp maybe_put_kw(list, key, value), do: Keyword.put(list, key, value)
end
