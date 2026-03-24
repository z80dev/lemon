defmodule LemonChannels.Adapters.ModelPolicyShared do
  @moduledoc """
  Shared ModelPolicyAdapter logic for all channel transports.

  Provides model and thinking-level resolution with session overrides
  (ephemeral) and persistent policy storage via `LemonCore.ModelPolicy`.

  ## Usage

      defmodule MyAdapter do
        use LemonChannels.Adapters.ModelPolicyShared

        @impl true
        def channel_name, do: "telegram"

        @impl true
        def build_route(account_id, chat_id, thread_id) do
          thread_str = if is_integer(thread_id), do: to_string(thread_id), else: nil
          Route.new("telegram", account_id, to_string(chat_id), thread_str)
        end

        @impl true
        def session_get(session_key), do: ...

        @impl true
        def session_put(session_key, model), do: ...

        @impl true
        def format_source_labels, do: %{topic: "topic default", chat: "chat default"}
      end

  ## Optional callbacks

  - `session_delete/1` — for channels that support clearing session overrides
  - `legacy_model_fallback/3` — for channels with pre-ModelPolicy data
  - `legacy_thinking_fallback/3` — for channels with pre-ModelPolicy thinking data
  - `chat_id_guard/1` — override the default guard type check
  """

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route

  @thinking_levels ~w(off minimal low medium high xhigh)
  @placeholder_model_id "_thinking_only"

  @callback channel_name() :: String.t()
  @callback build_route(account_id :: String.t(), chat_id :: term(), thread_id :: term()) ::
              Route.t()
  @callback session_get(session_key :: String.t()) :: String.t() | nil
  @callback session_put(session_key :: String.t(), model :: String.t()) :: :ok
  @callback format_source_labels() :: %{topic: String.t(), chat: String.t()}

  @optional_callbacks session_delete: 1,
                      legacy_model_fallback: 3,
                      legacy_thinking_fallback: 3,
                      clear_legacy_thinking: 1
  @callback session_delete(session_key :: String.t()) :: :ok
  @callback legacy_model_fallback(
              account_id :: String.t(),
              chat_id :: term(),
              thread_id :: term()
            ) :: String.t() | nil
  @callback legacy_thinking_fallback(
              account_id :: String.t(),
              chat_id :: term(),
              thread_id :: term()
            ) :: String.t() | nil
  @callback clear_legacy_thinking(legacy_key :: term()) :: term()

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour LemonChannels.Adapters.ModelPolicyShared

      alias LemonCore.ModelPolicy
      alias LemonCore.ModelPolicy.Route

      require Logger

      import LemonChannels.Adapters.ModelPolicyShared,
        only: [
          normalize_thinking_level: 1,
          thinking_level_atom: 1,
          normalize_model_id: 1,
          placeholder_only_policy?: 1,
          policy_model_id: 1,
          resolve_policy_model: 1,
          exact_policy_thinking_level: 1,
          placeholder_model_id: 0
        ]

      # ======================================================================
      # Session Overrides (ephemeral, per-session)
      # ======================================================================

      @spec session_model_override(term()) :: binary() | nil
      def session_model_override(session_key) when is_binary(session_key) do
        case session_get(session_key) do
          model when is_binary(model) and model != "" -> model
          _ -> nil
        end
      rescue
        _ -> nil
      end

      def session_model_override(_session_key), do: nil

      @spec put_session_model_override(term(), term()) :: :ok
      def put_session_model_override(session_key, model)
          when is_binary(session_key) and is_binary(model) do
        session_put(session_key, model)
        :ok
      rescue
        _ -> :ok
      end

      def put_session_model_override(_session_key, _model), do: :ok

      # ======================================================================
      # Combined Resolution (session + policy + optional legacy fallback)
      # ======================================================================

      @spec resolve_model_hint(binary() | nil, term(), term(), term()) ::
              {binary() | nil, :session | :future | nil}
      def resolve_model_hint(account_id, session_key, chat_id, thread_id)
          when is_binary(session_key) do
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
      def resolve_thinking_hint(account_id, chat_id, thread_id) do
        account_id = account_id || "default"

        topic_level =
          if has_thread?(thread_id),
            do: default_thinking_preference(account_id, chat_id, thread_id),
            else: nil

        chat_level = default_thinking_preference(account_id, chat_id, nil)

        inherited_level =
          LemonChannels.Adapters.ModelPolicyShared.resolved_policy_thinking_level(
            __MODULE__,
            account_id,
            chat_id,
            thread_id
          )

        cond do
          is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
          is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
          is_binary(inherited_level) and inherited_level != "" -> {inherited_level, nil}
          true -> {nil, nil}
        end
      rescue
        _ -> {nil, nil}
      end

      @spec format_thinking_line(term(), term()) :: binary()
      def format_thinking_line(level, source) when is_binary(level) and level != "" do
        labels = format_source_labels()

        case source do
          :topic -> "#{level} (#{labels.topic})"
          :chat -> "#{level} (#{labels.chat})"
          _ -> level
        end
      end

      def format_thinking_line(_level, _source) do
        LemonChannels.Adapters.ModelPolicyShared.default_thinking_line()
      end

      # ======================================================================
      # Persistent Model Preferences (ModelPolicy + optional legacy fallback)
      # ======================================================================

      @spec default_model_preference(binary() | nil, term(), term()) :: binary() | nil
      def default_model_preference(account_id, chat_id, thread_id) do
        account_id = account_id || "default"
        route = build_route(account_id, chat_id, thread_id)

        case resolve_policy_model(route) do
          nil ->
            if function_exported?(__MODULE__, :legacy_model_fallback, 3) do
              apply(__MODULE__, :legacy_model_fallback, [account_id, chat_id, thread_id])
            else
              nil
            end

          model_id ->
            model_id
        end
      rescue
        _ -> nil
      end

      @spec put_default_model_preference(binary() | nil, term(), term(), term()) :: :ok
      def put_default_model_preference(account_id, chat_id, thread_id, model)
          when is_binary(model) do
        account_id = account_id || "default"
        route = build_route(account_id, chat_id, thread_id)
        existing = ModelPolicy.get(route)

        policy_opts = [
          set_by: channel_name(),
          reason: "Set via #{String.capitalize(channel_name())} /model command"
        ]

        policy_opts =
          case existing do
            %{thinking_level: thinking_level} when not is_nil(thinking_level) ->
              Keyword.put(policy_opts, :thinking_level, thinking_level)

            _ ->
              policy_opts
          end

        policy = ModelPolicy.new_policy(model, policy_opts)
        ModelPolicy.set(route, policy)
        :ok
      rescue
        _ -> :ok
      end

      def put_default_model_preference(_account_id, _chat_id, _thread_id, _model), do: :ok

      # ======================================================================
      # Persistent Thinking Preferences (ModelPolicy + optional legacy fallback)
      # ======================================================================

      @spec default_thinking_preference(binary() | nil, term(), term()) :: binary() | nil
      def default_thinking_preference(account_id, chat_id, thread_id)
          when is_binary(account_id) do
        route = build_route(account_id, chat_id, thread_id)

        case exact_policy_thinking_level(route) do
          nil ->
            if function_exported?(__MODULE__, :legacy_thinking_fallback, 3) do
              apply(__MODULE__, :legacy_thinking_fallback, [account_id, chat_id, thread_id])
            else
              nil
            end

          level ->
            level
        end
      rescue
        _ -> nil
      end

      def default_thinking_preference(_account_id, _chat_id, _thread_id), do: nil

      # Arity-4 variant accepted by transport delegates (ignores _levels)
      def default_thinking_preference(account_id, chat_id, thread_id, _levels),
        do: default_thinking_preference(account_id, chat_id, thread_id)

      @spec put_default_thinking_preference(binary() | nil, term(), term(), term()) :: :ok
      def put_default_thinking_preference(account_id, chat_id, thread_id, level)
          when is_binary(level) do
        normalized = normalize_thinking_level(level)

        if is_binary(normalized) and normalized != "" do
          account_id = account_id || "default"
          route = build_route(account_id, chat_id, thread_id)
          thinking_atom = thinking_level_atom(normalized)

          existing = ModelPolicy.get(route)

          policy =
            case existing do
              nil ->
                ModelPolicy.new_policy(placeholder_model_id(),
                  thinking_level: thinking_atom,
                  set_by: channel_name(),
                  reason: "Set via #{String.capitalize(channel_name())} /thinking command"
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
      def clear_default_thinking_preference(account_id, chat_id, thread_id) when is_binary(account_id) do
        account_id = account_id || "default"
        had_override? = is_binary(default_thinking_preference(account_id, chat_id, thread_id))

        route = build_route(account_id, chat_id, thread_id)

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

        if function_exported?(__MODULE__, :clear_legacy_thinking, 1) do
          apply(__MODULE__, :clear_legacy_thinking, [{account_id, chat_id, thread_id}])
        end

        had_override?
      rescue
        _ -> false
      end

      def clear_default_thinking_preference(_account_id, _chat_id, _thread_id), do: false

      # Arity-4 variant accepted by transport delegates (ignores _levels)
      def clear_default_thinking_preference(account_id, chat_id, thread_id, _levels),
        do: clear_default_thinking_preference(account_id, chat_id, thread_id)

      # ======================================================================
      # Route helpers
      # ======================================================================

      @spec route_for(map() | String.t(), term(), term()) :: Route.t()
      def route_for(%{account_id: account_id}, chat_id, thread_id) do
        route_for(account_id || "default", chat_id, thread_id)
      end

      def route_for(account_id, chat_id, thread_id) when is_binary(account_id) do
        build_route(account_id, chat_id, thread_id)
      end

      # ======================================================================
      # Private helpers
      # ======================================================================

      defp has_thread?(thread_id) when is_integer(thread_id), do: true
      defp has_thread?(thread_id) when is_binary(thread_id) and thread_id != "", do: true
      defp has_thread?(_), do: false

      defoverridable resolve_model_hint: 4,
                     resolve_thinking_hint: 3,
                     default_model_preference: 3,
                     put_default_model_preference: 4,
                     default_thinking_preference: 3,
                     put_default_thinking_preference: 4,
                     clear_default_thinking_preference: 3,
                     format_thinking_line: 2,
                     session_model_override: 1,
                     put_session_model_override: 2,
                     route_for: 3
    end
  end

  # ===========================================================================
  # Public helper functions (called from injected code)
  # ===========================================================================

  def resolved_policy_thinking_level(module, account_id, chat_id, thread_id)
      when is_binary(account_id) do
    account_id
    |> module.build_route(chat_id, thread_id)
    |> ModelPolicy.resolve_thinking_level()
    |> normalize_thinking_level()
  end

  def default_thinking_line do
    cfg = LemonCore.Config.cached()
    agent = get_agent_map(cfg)
    default = agent[:default_thinking_level] || agent["default_thinking_level"] || "medium"
    "#{default} (default)"
  end

  defp get_agent_map(%{agent: agent}) when is_map(agent), do: agent
  defp get_agent_map(_), do: %{}

  # ===========================================================================
  # Public utility functions (imported by adapters)
  # ===========================================================================

  def normalize_thinking_level(nil), do: nil

  def normalize_thinking_level(level) when is_atom(level) do
    str = Atom.to_string(level)
    if str in @thinking_levels, do: str, else: nil
  end

  def normalize_thinking_level(level) when is_binary(level) do
    normalized = String.downcase(String.trim(level))
    if normalized in @thinking_levels, do: normalized, else: nil
  end

  def normalize_thinking_level(_), do: nil

  def thinking_level_atom(level) when is_binary(level) do
    case level do
      "off" -> :off
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
    end
  end

  def normalize_model_id(model_id) when is_binary(model_id) do
    normalized = String.trim(model_id)

    if normalized != "" and normalized != @placeholder_model_id do
      normalized
    else
      nil
    end
  end

  def normalize_model_id(_), do: nil

  def placeholder_only_policy?(policy) when is_map(policy) do
    is_nil(Map.get(policy, :thinking_level)) and
      is_nil(normalize_model_id(Map.get(policy, :model_id)))
  end

  def placeholder_only_policy?(_policy), do: false

  def policy_model_id(%{model_id: model_id}) when is_binary(model_id),
    do: normalize_model_id(model_id)

  def policy_model_id(_), do: nil

  def resolve_policy_model(%Route{} = route) do
    route
    |> Route.precedence_keys()
    |> Enum.find_value(fn key ->
      key
      |> Route.from_key()
      |> ModelPolicy.get()
      |> policy_model_id()
    end)
  end

  def exact_policy_thinking_level(%Route{} = route) do
    case ModelPolicy.get(route) do
      %{thinking_level: level} -> normalize_thinking_level(level)
      _ -> nil
    end
  end

  def placeholder_model_id, do: @placeholder_model_id
end
