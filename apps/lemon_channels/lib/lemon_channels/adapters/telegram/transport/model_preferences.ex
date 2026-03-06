defmodule LemonChannels.Adapters.Telegram.Transport.ModelPreferences do
  @moduledoc false

  alias LemonChannels.Telegram.StateStore
  alias LemonCore.ChatScope

  @thinking_levels ~w(off minimal low medium high xhigh)

  @spec resolve_model_hint(binary() | nil, term(), term(), term()) ::
          {binary() | nil, :session | :future | nil}
  def resolve_model_hint(account_id, session_key, chat_id, thread_id)
      when is_binary(session_key) and is_integer(chat_id) do
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
  def resolve_thinking_hint(account_id, chat_id, thread_id) when is_integer(chat_id) do
    account_id = account_id || "default"

    topic_level =
      if is_integer(thread_id),
        do: default_thinking_preference(account_id, chat_id, thread_id),
        else: nil

    chat_level = default_thinking_preference(account_id, chat_id, nil)

    cond do
      is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
      is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
      true -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  def resolve_thinking_hint(_account_id, _chat_id, _thread_id), do: {nil, nil}

  def resolve_thinking_hint(account_id, chat_id, thread_id, _levels),
    do: resolve_thinking_hint(account_id, chat_id, thread_id)

  @spec format_thinking_line(term(), term()) :: binary()
  def format_thinking_line(level, source) when is_binary(level) and level != "" do
    case source do
      :topic -> "#{level} (topic default)"
      :chat -> "#{level} (chat default)"
      _ -> level
    end
  end

  def format_thinking_line(_level, _source), do: "(default)"

  @spec session_model_override(term()) :: binary() | nil
  def session_model_override(session_key) when is_binary(session_key) do
    case StateStore.get_session_model(session_key) do
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
    StateStore.put_session_model(session_key, model)
    :ok
  rescue
    _ -> :ok
  end

  def put_session_model_override(_session_key, _model), do: :ok

  @spec default_model_preference(binary() | nil, term(), term()) :: binary() | nil
  def default_model_preference(account_id, chat_id, thread_id) when is_integer(chat_id) do
    key = {account_id || "default", chat_id, thread_id}

    case StateStore.get_default_model(key) do
      %{model: model} when is_binary(model) and model != "" -> model
      %{"model" => model} when is_binary(model) and model != "" -> model
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def default_model_preference(_account_id, _chat_id, _thread_id), do: nil

  @spec put_default_model_preference(binary() | nil, term(), term(), term()) :: :ok
  def put_default_model_preference(account_id, chat_id, thread_id, model)
      when is_integer(chat_id) and is_binary(model) do
    key = {account_id || "default", chat_id, thread_id}

    StateStore.put_default_model(key, %{
      model: model,
      updated_at_ms: System.system_time(:millisecond)
    })

    :ok
  rescue
    _ -> :ok
  end

  def put_default_model_preference(_account_id, _chat_id, _thread_id, _model), do: :ok

  @spec default_thinking_preference(binary() | nil, term(), term()) :: binary() | nil
  def default_thinking_preference(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    key = {account_id, chat_id, thread_id}

    case StateStore.get_default_thinking(key) do
      %{thinking_level: level} -> normalize_thinking_level(level)
      %{"thinking_level" => level} -> normalize_thinking_level(level)
      level -> normalize_thinking_level(level)
    end
  rescue
    _ -> nil
  end

  def default_thinking_preference(_account_id, _chat_id, _thread_id), do: nil

  def default_thinking_preference(account_id, chat_id, thread_id, _levels),
    do: default_thinking_preference(account_id, chat_id, thread_id)

  @spec put_default_thinking_preference(binary() | nil, term(), term(), term()) :: :ok
  def put_default_thinking_preference(account_id, chat_id, thread_id, level)
      when is_integer(chat_id) and is_binary(level) do
    normalized = normalize_thinking_level(level)

    if is_binary(normalized) and normalized != "" do
      key = {account_id || "default", chat_id, thread_id}

      StateStore.put_default_thinking(key, %{
        thinking_level: normalized,
        updated_at_ms: System.system_time(:millisecond)
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  def put_default_thinking_preference(_account_id, _chat_id, _thread_id, _level), do: :ok

  def put_default_thinking_preference(account_id, chat_id, thread_id, level, _levels),
    do: put_default_thinking_preference(account_id, chat_id, thread_id, level)

  @spec clear_default_thinking_preference(binary() | nil, term(), term()) :: boolean()
  def clear_default_thinking_preference(account_id, chat_id, thread_id)
      when is_integer(chat_id) do
    account_id = account_id || "default"
    key = {account_id, chat_id, thread_id}
    had_override? = is_binary(default_thinking_preference(account_id, chat_id, thread_id))
    _ = StateStore.delete_default_thinking(key)
    had_override?
  rescue
    _ -> false
  end

  def clear_default_thinking_preference(_account_id, _chat_id, _thread_id), do: false

  def clear_default_thinking_preference(account_id, chat_id, thread_id, _levels),
    do: clear_default_thinking_preference(account_id, chat_id, thread_id)

  @spec normalize_thinking_level(term()) :: binary() | nil
  def normalize_thinking_level(level) when is_atom(level) do
    level |> Atom.to_string() |> normalize_thinking_level()
  end

  def normalize_thinking_level(level) when is_binary(level) do
    normalized = String.downcase(String.trim(level))
    if normalized in @thinking_levels, do: normalized, else: nil
  end

  def normalize_thinking_level(_), do: nil

  def normalize_thinking_level(level, _levels), do: normalize_thinking_level(level)

  @spec normalize_thinking_command_arg(term()) ::
          :status | :clear | {:set, binary()} | :invalid
  def normalize_thinking_command_arg(args) when is_binary(args) do
    case String.downcase(String.trim(args)) do
      "" -> :status
      "clear" -> :clear
      level when level in @thinking_levels -> {:set, level}
      _ -> :invalid
    end
  end

  def normalize_thinking_command_arg(_), do: :invalid

  @spec render_thinking_status(binary() | nil, ChatScope.t()) :: binary()
  def render_thinking_status(account_id, %ChatScope{} = scope) do
    account_id = account_id || "default"
    chat_id = scope.chat_id
    topic_id = scope.topic_id

    topic_level =
      if is_integer(topic_id),
        do: default_thinking_preference(account_id, chat_id, topic_id),
        else: nil

    chat_level = default_thinking_preference(account_id, chat_id, nil)

    {effective_level, source} =
      cond do
        is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
        is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
        true -> {nil, nil}
      end

    [
      "Thinking level for #{thinking_scope_label(scope)}: #{format_thinking_line(effective_level, source)}",
      if(is_binary(chat_level) and chat_level != "",
        do: "Chat default: #{chat_level}.",
        else: "Chat default: none."
      ),
      if(is_binary(topic_level) and topic_level != "",
        do: "Topic override: #{topic_level}.",
        else: "Topic override: none."
      ),
      thinking_usage()
    ]
    |> Enum.join("\n")
  rescue
    _ -> thinking_usage()
  end

  @spec render_thinking_set(ChatScope.t(), binary()) :: binary()
  def render_thinking_set(%ChatScope{topic_id: topic_id}, level)
      when is_integer(topic_id) and is_binary(level) do
    Enum.join(
      [
        "Thinking level set to #{level} for this topic.",
        "New runs in this topic will use this setting.",
        thinking_usage()
      ],
      "\n"
    )
  end

  def render_thinking_set(%ChatScope{}, level) when is_binary(level) do
    Enum.join(
      [
        "Thinking level set to #{level} for this chat.",
        "New runs in this chat will use this setting.",
        thinking_usage()
      ],
      "\n"
    )
  end

  def render_thinking_set(_scope, level) when is_binary(level),
    do: "Thinking level set to #{level}."

  @spec render_thinking_cleared(ChatScope.t(), boolean()) :: binary()
  def render_thinking_cleared(%ChatScope{topic_id: topic_id}, had_override?)
      when is_integer(topic_id) do
    if had_override?,
      do: "Cleared thinking level override for this topic.",
      else: "No /thinking override was set for this topic."
  end

  def render_thinking_cleared(%ChatScope{}, had_override?) do
    if had_override?,
      do: "Cleared thinking level override for this chat.",
      else: "No /thinking override was set for this chat."
  end

  def render_thinking_cleared(_scope, _had_override?), do: "Thinking level override cleared."

  @spec thinking_usage() :: binary()
  def thinking_usage, do: "Usage: /thinking [off|minimal|low|medium|high|xhigh|clear]"

  defp thinking_scope_label(%ChatScope{topic_id: topic_id}) when is_integer(topic_id),
    do: "this topic"

  defp thinking_scope_label(_), do: "this chat"
end
