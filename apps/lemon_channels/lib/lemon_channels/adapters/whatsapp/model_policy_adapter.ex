defmodule LemonChannels.Adapters.WhatsApp.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates WhatsApp with the unified ModelPolicy system.

  Provides model and thinking-level resolution for the WhatsApp transport.
  Uses session overrides (ephemeral, stored in ETS) and persistent policy
  storage via `LemonCore.ModelPolicy`. No legacy fallback needed — WhatsApp
  is a new channel with no pre-ModelPolicy data to migrate.
  """

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route

  require Logger

  @thinking_levels ~w(off minimal low medium high xhigh)
  @placeholder_model_id "_thinking_only"
  @session_table :whatsapp_session_models

  # ============================================================================
  # ETS Session Store (replaces Telegram's StateStore dependency)
  # ============================================================================

  def ensure_session_table do
    if :ets.whereis(@session_table) == :undefined do
      :ets.new(@session_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Session Overrides (ephemeral, per-session)
  # ============================================================================

  @spec session_model_override(term()) :: binary() | nil
  def session_model_override(session_key) when is_binary(session_key) do
    ensure_session_table()

    case :ets.lookup(@session_table, {:model, session_key}) do
      [{_, model}] when is_binary(model) and model != "" -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def session_model_override(_session_key), do: nil

  @spec put_session_model_override(term(), term()) :: :ok
  def put_session_model_override(session_key, model)
      when is_binary(session_key) and is_binary(model) do
    ensure_session_table()
    :ets.insert(@session_table, {{:model, session_key}, model})
    :ok
  rescue
    _ -> :ok
  end

  def put_session_model_override(_session_key, _model), do: :ok

  # ============================================================================
  # Combined Resolution (session + policy)
  # ============================================================================

  @spec resolve_model_hint(binary() | nil, term(), term(), term()) ::
          {binary() | nil, :session | :future | nil}
  def resolve_model_hint(account_id, session_key, chat_id, thread_id)
      when is_binary(session_key) and is_binary(chat_id) do
    case session_model_override(session_key) do
      model when is_binary(model) and model != "" ->
        {model, :session}

      _ ->
        case default_model_preference(account_id, chat_id, thread_id) do
          model when is_binary(model) and model != "" -> {model, :future}
          _ -> {nil, nil}
        end
    end
  rescue
    _ -> {nil, nil}
  end

  def resolve_model_hint(_account_id, _session_key, _chat_id, _thread_id), do: {nil, nil}

  @spec resolve_thinking_hint(binary() | nil, term(), term()) ::
          {binary() | nil, :topic | :chat | nil}
  def resolve_thinking_hint(account_id, chat_id, thread_id) when is_binary(chat_id) do
    account_id = account_id || "default"

    topic_level =
      if is_binary(thread_id) and thread_id != "",
        do: default_thinking_preference(account_id, chat_id, thread_id),
        else: nil

    chat_level = default_thinking_preference(account_id, chat_id, nil)
    inherited_level = resolved_policy_thinking_level(account_id, chat_id, thread_id)

    cond do
      is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
      is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
      is_binary(inherited_level) and inherited_level != "" -> {inherited_level, nil}
      true -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  def resolve_thinking_hint(_account_id, _chat_id, _thread_id), do: {nil, nil}

  @spec format_thinking_line(term(), term()) :: binary()
  def format_thinking_line(level, source) when is_binary(level) and level != "" do
    case source do
      :topic -> "#{level} (topic default)"
      :chat -> "#{level} (chat default)"
      _ -> level
    end
  end

  def format_thinking_line(_level, _source) do
    cfg = LemonCore.Config.cached()
    agent = get_agent_map(cfg)
    default = agent[:default_thinking_level] || agent["default_thinking_level"] || "medium"
    "#{default} (default)"
  end

  defp get_agent_map(%{agent: agent}) when is_map(agent), do: agent
  defp get_agent_map(_), do: %{}

  # ============================================================================
  # Persistent Model Preferences (ModelPolicy only, no legacy)
  # ============================================================================

  @spec default_model_preference(binary() | nil, term(), term()) :: binary() | nil
  def default_model_preference(account_id, chat_id, thread_id) when is_binary(chat_id) do
    account_id = account_id || "default"
    route = whatsapp_route(account_id, chat_id, thread_id)

    resolve_policy_model(route)
  rescue
    _ -> nil
  end

  def default_model_preference(_account_id, _chat_id, _thread_id), do: nil

  @spec put_default_model_preference(binary() | nil, term(), term(), term()) :: :ok
  def put_default_model_preference(account_id, chat_id, thread_id, model)
      when is_binary(chat_id) and is_binary(model) do
    account_id = account_id || "default"
    route = whatsapp_route(account_id, chat_id, thread_id)
    existing = ModelPolicy.get(route)

    policy_opts = [
      set_by: "whatsapp",
      reason: "Set via WhatsApp /model command"
    ]

    policy_opts =
      case existing do
        %{thinking_level: thinking_level} when not is_nil(thinking_level) ->
          Keyword.put(policy_opts, :thinking_level, thinking_level)

        _ ->
          policy_opts
      end

    policy =
      ModelPolicy.new_policy(
        model,
        policy_opts
      )

    ModelPolicy.set(route, policy)
    :ok
  rescue
    _ -> :ok
  end

  def put_default_model_preference(_account_id, _chat_id, _thread_id, _model), do: :ok

  # ============================================================================
  # Persistent Thinking Preferences (ModelPolicy only, no legacy)
  # ============================================================================

  @spec default_thinking_preference(binary() | nil, term(), term()) :: binary() | nil
  def default_thinking_preference(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_binary(chat_id) do
    exact_thinking_preference(account_id, chat_id, thread_id)
  rescue
    _ -> nil
  end

  def default_thinking_preference(_account_id, _chat_id, _thread_id), do: nil

  # Arity-4 variant accepted by transport delegates (ignores _levels)
  def default_thinking_preference(account_id, chat_id, thread_id, _levels),
    do: default_thinking_preference(account_id, chat_id, thread_id)

  @spec put_default_thinking_preference(binary() | nil, term(), term(), term()) :: :ok
  def put_default_thinking_preference(account_id, chat_id, thread_id, level)
      when is_binary(chat_id) and is_binary(level) do
    normalized = normalize_thinking_level(level)

    if is_binary(normalized) and normalized != "" do
      account_id = account_id || "default"
      route = whatsapp_route(account_id, chat_id, thread_id)
      thinking_atom = thinking_level_atom(normalized)

      # Get or create a policy at this route
      existing = ModelPolicy.get(route)

      policy =
        case existing do
          nil ->
            # Create a minimal policy just for thinking level.
            # Use a placeholder model_id since ModelPolicy requires one.
            ModelPolicy.new_policy(@placeholder_model_id,
              thinking_level: thinking_atom,
              set_by: "whatsapp",
              reason: "Set via WhatsApp /thinking command"
            )

          policy ->
            Map.put(policy, :thinking_level, thinking_atom)
        end

      ModelPolicy.set(route, policy)
    end

    :ok
  rescue
    _ -> :ok
  end

  def put_default_thinking_preference(_account_id, _chat_id, _thread_id, _level), do: :ok

  # Arity-5 variant accepted by transport delegates (ignores _levels)
  def put_default_thinking_preference(account_id, chat_id, thread_id, level, _levels),
    do: put_default_thinking_preference(account_id, chat_id, thread_id, level)

  @spec clear_default_thinking_preference(binary() | nil, term(), term()) :: boolean()
  def clear_default_thinking_preference(account_id, chat_id, thread_id)
      when is_binary(chat_id) do
    account_id = account_id || "default"
    had_override? = is_binary(default_thinking_preference(account_id, chat_id, thread_id))

    route = whatsapp_route(account_id, chat_id, thread_id)

    case ModelPolicy.get(route) do
      nil ->
        :ok

      %{thinking_level: _} = policy ->
        updated = Map.delete(policy, :thinking_level)

        if placeholder_only_policy?(updated) do
          ModelPolicy.clear(route)
        else
          ModelPolicy.set(route, updated)
        end

      _ ->
        :ok
    end

    had_override?
  rescue
    _ -> false
  end

  def clear_default_thinking_preference(_account_id, _chat_id, _thread_id), do: false

  # Arity-4 variant accepted by transport delegates (ignores _levels)
  def clear_default_thinking_preference(account_id, chat_id, thread_id, _levels),
    do: clear_default_thinking_preference(account_id, chat_id, thread_id)

  # ============================================================================
  # Route helpers
  # ============================================================================

  @spec route_for(map() | String.t(), binary(), binary() | nil) :: Route.t()
  def route_for(%{account_id: account_id}, chat_id, thread_id) do
    route_for(account_id || "default", chat_id, thread_id)
  end

  def route_for(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_binary(chat_id) do
    whatsapp_route(account_id, chat_id, thread_id)
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp whatsapp_route(account_id, chat_id, thread_id) do
    thread_str = if is_binary(thread_id) and thread_id != "", do: thread_id, else: nil
    Route.new("whatsapp", account_id, chat_id, thread_str)
  end

  defp resolve_policy_model(%Route{} = route) do
    route
    |> Route.precedence_keys()
    |> Enum.find_value(fn key ->
      key
      |> Route.from_key()
      |> ModelPolicy.get()
      |> policy_model_id()
    end)
  end

  defp exact_thinking_preference(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_binary(chat_id) do
    route = whatsapp_route(account_id, chat_id, thread_id)
    exact_policy_thinking_level(route)
  end

  defp exact_policy_thinking_level(%Route{} = route) do
    case ModelPolicy.get(route) do
      %{thinking_level: level} -> normalize_thinking_level(level)
      _ -> nil
    end
  end

  defp resolved_policy_thinking_level(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_binary(chat_id) do
    account_id
    |> whatsapp_route(chat_id, thread_id)
    |> ModelPolicy.resolve_thinking_level()
    |> normalize_thinking_level()
  end

  defp policy_model_id(%{model_id: model_id}) when is_binary(model_id),
    do: normalize_model_id(model_id)

  defp policy_model_id(_), do: nil

  defp normalize_model_id(model_id) when is_binary(model_id) do
    normalized = String.trim(model_id)

    if normalized != "" and normalized != @placeholder_model_id do
      normalized
    else
      nil
    end
  end

  defp normalize_model_id(_), do: nil

  defp placeholder_only_policy?(policy) when is_map(policy) do
    is_nil(Map.get(policy, :thinking_level)) and
      is_nil(normalize_model_id(Map.get(policy, :model_id)))
  end

  defp placeholder_only_policy?(_policy), do: false

  defp thinking_level_atom(level) when is_binary(level) do
    case level do
      "off" -> :off
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
    end
  end

  defp normalize_thinking_level(nil), do: nil

  defp normalize_thinking_level(level) when is_atom(level) do
    str = Atom.to_string(level)
    if str in @thinking_levels, do: str, else: nil
  end

  defp normalize_thinking_level(level) when is_binary(level) do
    normalized = String.downcase(String.trim(level))
    if normalized in @thinking_levels, do: normalized, else: nil
  end

  defp normalize_thinking_level(_), do: nil
end
