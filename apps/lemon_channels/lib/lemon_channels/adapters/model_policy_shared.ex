defmodule LemonChannels.Adapters.ModelPolicyShared do
  @moduledoc """
  Channel `/model` and `/thinking` preferences, stored in `LemonCore.PolicyStore`.

  A session override (`/model` → "this session") is the `:model` field of the
  session's `PolicyStore` row, the same row `sessions.patch` writes, so the
  control plane, web and TUI see it. A chat or thread default (`/model` →
  "future sessions", `/thinking`) is the `PolicyStore` chat row of the route
  `build_route/3` names. Channels only render these values and encode picker
  choices; `LemonRouter.ModelSelection` decides which one a run uses, from the
  session key alone, so a run never depends on what a channel put in its meta.

  Reads here feed rendering only: an unreadable row renders as unset, while the
  router's admission read of the same rows fails closed.

  ## Usage

      defmodule MyAdapter do
        use LemonChannels.Adapters.ModelPolicyShared

        @impl true
        def channel_name, do: "telegram"

        @impl true
        def build_route(account_id, chat_id, thread_id),
          do: {"telegram", account_id, to_string(chat_id), thread_id && to_string(thread_id)}

        @impl true
        def format_source_labels, do: %{topic: "topic default", chat: "chat default"}
      end
  """

  alias LemonCore.PolicyStore

  @thinking_levels ~w(off minimal low medium high xhigh auto)

  @callback channel_name() :: String.t()
  @callback build_route(account_id :: String.t(), chat_id :: term(), thread_id :: term()) ::
              PolicyStore.chat_route()
  @callback format_source_labels() :: %{topic: String.t(), chat: String.t()}

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour LemonChannels.Adapters.ModelPolicyShared

      alias LemonChannels.Adapters.ModelPolicyShared, as: Shared

      @spec session_model_override(term()) :: binary() | nil
      def session_model_override(session_key), do: Shared.session_model(session_key)

      @spec put_session_model_override(term(), term()) :: :ok | {:error, term()}
      def put_session_model_override(session_key, model),
        do: Shared.put_session_model(session_key, model)

      @spec delete_session_model_override(term()) :: :ok | {:error, term()}
      def delete_session_model_override(session_key), do: Shared.delete_session_model(session_key)

      @doc "The model shown for a session: its override, else the chat default (`:future`)."
      @spec resolve_model_hint(binary() | nil, term(), term(), term()) ::
              {binary() | nil, :session | :future | nil}
      def resolve_model_hint(account_id, session_key, chat_id, thread_id)
          when is_binary(session_key) do
        case session_model_override(session_key) do
          model when is_binary(model) ->
            {model, :session}

          nil ->
            case default_model_preference(account_id, chat_id, thread_id) do
              model when is_binary(model) -> {model, :future}
              nil -> {nil, nil}
            end
        end
      end

      def resolve_model_hint(_account_id, _session_key, _chat_id, _thread_id), do: {nil, nil}

      @spec resolve_thinking_hint(binary() | nil, term(), term()) ::
              {binary() | nil, :topic | :chat | nil}
      def resolve_thinking_hint(account_id, chat_id, thread_id) do
        account_id = account_id || "default"
        route = build_route(account_id, chat_id, thread_id)
        chat_route = build_route(account_id, chat_id, nil)

        case Shared.resolved_defaults(route) do
          %{thinking_level: level, thinking_route: ^route}
          when is_binary(level) and route != chat_route ->
            {level, :topic}

          %{thinking_level: level, thinking_route: ^chat_route} when is_binary(level) ->
            {level, :chat}

          %{thinking_level: level} ->
            {level, nil}
        end
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

      def format_thinking_line(_level, _source), do: Shared.default_thinking_line()

      @doc "The chat default model inherited by `thread_id` (thread, chat, account, channel)."
      @spec default_model_preference(binary() | nil, term(), term()) :: binary() | nil
      def default_model_preference(account_id, chat_id, thread_id) do
        (account_id || "default")
        |> build_route(chat_id, thread_id)
        |> Shared.resolved_defaults()
        |> Map.fetch!(:model)
      end

      @spec put_default_model_preference(binary() | nil, term(), term(), term()) ::
              :ok | {:error, term()}
      def put_default_model_preference(account_id, chat_id, thread_id, model) do
        case Shared.normalize_model_id(model) do
          nil ->
            :ok

          model ->
            (account_id || "default")
            |> build_route(chat_id, thread_id)
            |> Shared.put_chat_field(:model, model, channel_name())
        end
      end

      @doc "The thinking level stored on exactly this thread or chat (no inheritance)."
      @spec default_thinking_preference(binary() | nil, term(), term()) :: binary() | nil
      def default_thinking_preference(account_id, chat_id, thread_id)
          when is_binary(account_id) do
        account_id
        |> build_route(chat_id, thread_id)
        |> Shared.exact_thinking_level()
      end

      def default_thinking_preference(_account_id, _chat_id, _thread_id), do: nil

      @spec put_default_thinking_preference(binary() | nil, term(), term(), term()) ::
              :ok | {:error, term()}
      def put_default_thinking_preference(account_id, chat_id, thread_id, level) do
        case Shared.normalize_thinking_level(level) do
          nil ->
            :ok

          normalized ->
            (account_id || "default")
            |> build_route(chat_id, thread_id)
            |> Shared.put_chat_field(:thinking_level, normalized, channel_name())
        end
      end

      @doc "Clears this thread's or chat's own thinking level; true when one was set."
      @spec clear_default_thinking_preference(binary() | nil, term(), term()) :: boolean()
      def clear_default_thinking_preference(account_id, chat_id, thread_id)
          when is_binary(account_id) do
        route = build_route(account_id, chat_id, thread_id)
        had_override? = is_binary(Shared.exact_thinking_level(route))
        _ = Shared.put_chat_field(route, :thinking_level, nil, channel_name())
        had_override?
      end

      def clear_default_thinking_preference(_account_id, _chat_id, _thread_id), do: false

      @spec route_for(map() | String.t(), term(), term()) :: PolicyStore.chat_route()
      def route_for(%{account_id: account_id}, chat_id, thread_id),
        do: route_for(account_id || "default", chat_id, thread_id)

      def route_for(account_id, chat_id, thread_id) when is_binary(account_id),
        do: build_route(account_id, chat_id, thread_id)
    end
  end

  @doc false
  def session_model(session_key) when is_binary(session_key) do
    case PolicyStore.fetch_session(session_key) do
      {:ok, %{} = row} -> row |> Map.get(:model) |> normalize_model_id()
      _absent_or_unreadable -> nil
    end
  end

  def session_model(_session_key), do: nil

  @doc false
  def put_session_model(session_key, model) when is_binary(session_key) do
    case normalize_model_id(model) do
      nil ->
        :ok

      model ->
        session_result(
          PolicyStore.update_session(session_key, &Map.put(&1 || %{}, :model, model))
        )
    end
  end

  def put_session_model(_session_key, _model), do: :ok

  @doc false
  def delete_session_model(session_key) when is_binary(session_key) do
    case PolicyStore.fetch_session(session_key) do
      {:ok, %{model: _}} ->
        session_result(PolicyStore.update_session(session_key, &Map.delete(&1 || %{}, :model)))

      {:ok, _no_model} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def delete_session_model(_session_key), do: :ok

  defp session_result({:ok, _row}), do: :ok
  defp session_result({:error, _reason} = error), do: error

  @doc false
  def resolved_defaults(route) do
    case PolicyStore.resolve_chat(route) do
      {:ok, defaults} ->
        defaults

      {:error, _reason} ->
        %{model: nil, model_route: nil, thinking_level: nil, thinking_route: nil}
    end
  end

  @doc false
  def exact_thinking_level(route) do
    case PolicyStore.fetch_chat(route) do
      {:ok, %{} = row} -> row |> Map.get(:thinking_level) |> normalize_thinking_level()
      _absent_or_unreadable -> nil
    end
  end

  @doc false
  # Sets (or with `nil` clears) one field of the chat row; a row left with
  # neither a model nor a thinking level is deleted.
  def put_chat_field(route, field, value, set_by) do
    update = fn current ->
      row = current || %{}
      row = if is_nil(value), do: Map.delete(row, field), else: Map.put(row, field, value)

      if Map.has_key?(row, :model) or Map.has_key?(row, :thinking_level),
        do: Map.merge(row, %{set_by: set_by, updated_at_ms: System.system_time(:millisecond)}),
        else: nil
    end

    case PolicyStore.update_chat(route, update) do
      {:ok, _row} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def default_thinking_line do
    cfg = LemonCore.Config.cached()
    agent = get_agent_map(cfg)
    default = agent[:default_thinking_level] || agent["default_thinking_level"] || "medium"
    "#{default} (default)"
  end

  defp get_agent_map(%{agent: agent}) when is_map(agent), do: agent
  defp get_agent_map(_), do: %{}

  def normalize_thinking_level(level) when is_atom(level) and not is_nil(level),
    do: level |> Atom.to_string() |> normalize_thinking_level()

  def normalize_thinking_level(level) when is_binary(level) do
    normalized = String.downcase(String.trim(level))
    if normalized in @thinking_levels, do: normalized, else: nil
  end

  def normalize_thinking_level(_), do: nil

  def normalize_model_id(model_id) when is_binary(model_id) do
    case String.trim(model_id) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_model_id(_), do: nil
end
