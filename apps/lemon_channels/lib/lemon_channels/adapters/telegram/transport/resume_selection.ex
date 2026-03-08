defmodule LemonChannels.Adapters.Telegram.Transport.ResumeSelection do
  @moduledoc false

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonChannels.EngineRegistry
  alias LemonCore.{EngineCatalog, ResumeToken}
  alias LemonCore.RunStore

  @type callbacks :: %{
          required(:extract_chat_ids) => (map() -> {integer() | nil, integer() | nil}),
          required(:extract_message_ids) => (map() ->
                                               {integer() | nil, integer() | nil, integer() | nil}),
          required(:build_session_key) => (map(), map(), LemonCore.ChatScope.t() -> binary()),
          required(:normalize_msg_id) => (term() -> integer() | nil),
          required(:send_system_message) => (map(),
                                             integer(),
                                             integer()
                                             | nil,
                                             integer()
                                             | nil,
                                             binary() ->
                                               term()),
          required(:submit_inbound_now) => (map(), map() -> map())
        }

  @spec maybe_switch_session_from_reply(map(), map(), callbacks) :: {map(), map()}
  def maybe_switch_session_from_reply(state, inbound, callbacks) do
    meta = inbound.meta || %{}

    reply_to_id =
      callbacks.normalize_msg_id.(inbound.message.reply_to_id || inbound.meta[:reply_to_id])

    cond do
      meta[:disable_auto_resume] == true or meta["disable_auto_resume"] == true ->
        {state, inbound}

      not is_integer(reply_to_id) ->
        {state, inbound}

      true ->
        {chat_id, thread_id} = callbacks.extract_chat_ids.(inbound)

        if not is_integer(chat_id) do
          {state, inbound}
        else
          scope = %LemonCore.ChatScope{
            transport: :telegram,
            chat_id: chat_id,
            topic_id: thread_id
          }

          session_key = callbacks.build_session_key.(state, inbound, scope)

          {resume, source} =
            resume_from_reply(state.account_id, inbound, chat_id, thread_id, reply_to_id)

          if match?(%ResumeToken{}, resume) and
               switching_session?(PerChatState.safe_get_chat_state(session_key), resume) do
            Logger.debug(
              "Telegram switching session from reply chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} " <>
                "source=#{inspect(source)} resume=#{inspect(resume)} session_key=#{inspect(session_key)}"
            )

            PerChatState.set_chat_resume(scope, session_key, resume)

            inbound =
              case source do
                :reply_text -> inbound
                :msg_index -> maybe_prefix_resume_to_prompt(inbound, resume)
              end

            {state, inbound}
          else
            {state, inbound}
          end
        end
    end
  rescue
    _ -> {state, inbound}
  end

  @spec handle_resume_command(map(), map(), callbacks) :: map()
  def handle_resume_command(state, inbound, callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)

    if not is_integer(chat_id) do
      state
    else
      scope = %LemonCore.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = callbacks.build_session_key.(state, inbound, scope)

      args =
        LemonChannels.Adapters.Telegram.Transport.Commands.telegram_command_args(
          inbound.message.text,
          "resume"
        ) || ""

      cond do
        args == "" ->
          text =
            case list_recent_sessions(session_key, limit: 20) do
              [] ->
                "No sessions found yet."

              list ->
                Enum.join(
                  [
                    "Available sessions (most recent first):",
                    list
                    |> Enum.with_index(1)
                    |> Enum.map(fn {%{resume: r}, idx} -> "#{idx}. #{format_session_ref(r)}" end)
                    |> Enum.join("\n"),
                    "Use /resume <number> to switch sessions."
                  ],
                  "\n\n"
                )
            end

          _ = callbacks.send_system_message.(state, chat_id, thread_id, user_msg_id, text)
          state

        true ->
          sessions = list_recent_sessions(session_key, limit: 50)

          {resume, prompt_part} =
            case parse_inline_resume_args(args) do
              {%ResumeToken{} = inline_resume, inline_prompt} ->
                {inline_resume, inline_prompt}

              nil ->
                {selector, selector_prompt} =
                  case String.split(args, ~r/\s+/, parts: 2) do
                    [a] -> {a, ""}
                    [a, rest] -> {a, String.trim(rest || "")}
                    _ -> {args, ""}
                  end

                {resolve_resume_selector(selector, sessions), selector_prompt}
            end

          if match?(%ResumeToken{}, resume) do
            PerChatState.set_chat_resume(scope, session_key, resume)

            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Resuming session: #{format_session_ref(resume)}"
              )

            if prompt_part != "" do
              inbound =
                inbound
                |> put_in([Access.key!(:message), :text], prompt_part)
                |> maybe_prefix_resume_to_prompt(resume)

              callbacks.submit_inbound_now.(state, inbound)
            else
              state
            end
          else
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Couldn't find that session. Try /resume to list sessions."
              )

            state
          end
      end
    end
  rescue
    _ -> state
  end

  defp parse_inline_resume_args(args) when is_binary(args) do
    case String.split(String.trim(args), ~r/\s+/, parts: 3) do
      [engine_id, token] ->
        build_inline_resume(engine_id, token, "")

      [engine_id, token, prompt_part] ->
        build_inline_resume(engine_id, token, String.trim(prompt_part || ""))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_inline_resume_args(_), do: nil

  defp build_inline_resume(engine_id, token, prompt_part) do
    normalized_engine_id = String.downcase(String.trim(engine_id || ""))
    normalized_token = String.trim(token || "")

    case EngineCatalog.normalize(normalized_engine_id) do
      normalized_engine when is_binary(normalized_engine) and normalized_token != "" ->
        {%ResumeToken{engine: normalized_engine, value: normalized_token}, prompt_part}

      _ ->
        nil
    end
  end

  @spec resolve_resume_selector(binary(), list()) :: ResumeToken.t() | nil
  def resolve_resume_selector(selector, sessions) when is_binary(selector) do
    selector = String.trim(selector)

    cond do
      selector == "" ->
        nil

      Regex.match?(~r/^\d+$/, selector) ->
        case Enum.at(sessions, String.to_integer(selector) - 1) do
          %{resume: %ResumeToken{} = resume} -> resume
          _ -> nil
        end

      true ->
        case parse_resume_selector(selector) do
          %ResumeToken{} = token ->
            token

          nil ->
            find_by_token_value(selector, sessions)
        end
    end
  rescue
    _ -> nil
  end

  @spec list_recent_sessions(binary(), keyword()) :: list()
  def list_recent_sessions(session_key, opts) when is_binary(session_key) do
    limit = Keyword.get(opts, :limit, 20)

    session_key
    |> RunStore.history(limit: limit * 5)
    |> Enum.map(fn {_run_id, data} ->
      %{resume: extract_resume_from_history(data), started_at: data[:started_at] || 0}
    end)
    |> Enum.filter(fn %{resume: resume} -> match?(%ResumeToken{}, resume) end)
    |> Enum.sort_by(& &1.started_at, :desc)
    |> Enum.reduce({[], MapSet.new()}, fn %{resume: resume, started_at: ts}, {acc, seen} ->
      key = {resume.engine, resume.value}

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[%{resume: resume, started_at: ts} | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  def list_recent_sessions(_session_key, _opts), do: []

  @spec extract_explicit_resume_and_strip(String.t() | term()) ::
          {ResumeToken.t() | nil, String.t() | term()}
  def extract_explicit_resume_and_strip(text) when is_binary(text) do
    case parse_resume_selector(text) do
      %ResumeToken{} = token ->
        stripped =
          text
          |> String.split("\n")
          |> Enum.reject(&(match?(%ResumeToken{}, parse_resume_selector(&1))))
          |> Enum.join("\n")
          |> String.trim()

        {token, if(stripped == "", do: "Continue.", else: stripped)}

      nil ->
        {nil, text}
    end
  rescue
    _ -> {nil, text}
  end

  def extract_explicit_resume_and_strip(text), do: {nil, text}

  @spec maybe_apply_selected_resume(binary() | nil, map(), binary()) :: map()
  def maybe_apply_selected_resume(account_id, inbound, original_text) do
    meta = inbound.meta || %{}

    cond do
      meta[:disable_auto_resume] == true or meta["disable_auto_resume"] == true ->
        inbound

      LemonChannels.Adapters.Telegram.Transport.Commands.command_message?(original_text) ->
        inbound

      meta[:fork_when_busy] == true or meta["fork_when_busy"] == true ->
        inbound

      match?(%ResumeToken{}, parse_resume_selector(inbound.message.text || "")) ->
        inbound

      true ->
        chat_id = inbound.meta[:chat_id]
        thread_id = inbound.meta[:thread_id] || inbound.meta[:topic_id]

        if is_integer(chat_id) do
          case LemonChannels.Telegram.StateStore.get_selected_resume(
                 {account_id || "default", chat_id, thread_id}
               ) do
            %ResumeToken{} = token ->
              Logger.debug(
                "Telegram applying selected resume chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} " <>
                  "resume=#{inspect(token)}"
              )

              maybe_prefix_resume_to_prompt(inbound, token)

            _ ->
              inbound
          end
        else
          inbound
        end
    end
  rescue
    _ -> inbound
  end

  @spec extract_resume_from_history(term()) :: ResumeToken.t() | nil
  def extract_resume_from_history(data) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    completed = summary[:completed] || summary["completed"]

    resume =
      cond do
        is_map(completed) and is_struct(completed) and Map.has_key?(completed, :resume) ->
          Map.get(completed, :resume)

        is_map(completed) ->
          completed[:resume] || completed["resume"]

        true ->
          nil
      end

    case resume do
      %ResumeToken{} = token ->
        token

      %{engine: engine, value: value} when is_binary(engine) and is_binary(value) ->
        %ResumeToken{engine: engine, value: value}

      %{"engine" => engine, "value" => value} when is_binary(engine) and is_binary(value) ->
        %ResumeToken{engine: engine, value: value}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def extract_resume_from_history(_), do: nil

  defp resume_from_reply(account_id, inbound, chat_id, thread_id, reply_to_id) do
    reply_text = inbound.meta[:reply_to_text]

    cond do
      is_binary(reply_text) and reply_text != "" ->
        case parse_resume_selector(reply_text) do
          %ResumeToken{} = token -> {token, :reply_text}
          _ -> {nil, nil}
        end

      true ->
        generation = PerChatState.current_thread_generation(account_id, chat_id, thread_id)

        token =
          ResumeIndexStore.get_resume(account_id || "default", chat_id, thread_id, reply_to_id,
            generation: generation
          )

        case token do
          %ResumeToken{} = token -> {token, :msg_index}
          _ -> {nil, nil}
        end
    end
  rescue
    _ -> {nil, nil}
  end

  @spec switching_session?(term(), ResumeToken.t() | term()) :: boolean()
  def switching_session?(nil, %ResumeToken{}), do: true

  def switching_session?(%{} = chat_state, %ResumeToken{} = resume) do
    last_engine = chat_state[:last_engine] || chat_state["last_engine"] || chat_state.last_engine

    last_token =
      chat_state[:last_resume_token] || chat_state["last_resume_token"] ||
        chat_state.last_resume_token

    last_engine != resume.engine or last_token != resume.value
  rescue
    _ -> true
  end

  def switching_session?(_chat_state, _resume), do: true

  @spec maybe_prefix_resume_to_prompt(map(), ResumeToken.t()) :: map()
  def maybe_prefix_resume_to_prompt(inbound, %ResumeToken{} = resume) do
    %{inbound | meta: (inbound.meta || %{}) |> Map.put(:resume, resume)}
  rescue
    _ -> inbound
  end

  defp find_by_token_value(value, sessions) do
    trimmed = String.trim(value || "")

    Enum.find_value(sessions, fn
      %{resume: %ResumeToken{value: ^trimmed} = resume} -> resume
      _ -> nil
    end)
  end

  defp parse_resume_selector(selector) when is_binary(selector) do
    case EngineRegistry.extract_resume(selector) do
      {:ok, %ResumeToken{} = token} ->
        token

      _ ->
        case String.split(selector, ~r/\s+/, parts: 2) do
          [engine_id, token_value] ->
            case EngineCatalog.normalize(engine_id) do
              normalized_engine when is_binary(normalized_engine) and is_binary(token_value) ->
                trimmed_token = String.trim(token_value)
                if trimmed_token == "", do: nil, else: %ResumeToken{engine: normalized_engine, value: trimmed_token}

              _ ->
                nil
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp parse_resume_selector(_), do: nil

  @spec format_resume_line(ResumeToken.t()) :: String.t()
  def format_resume_line(%ResumeToken{} = resume), do: ResumeToken.format_plain(resume)

  @spec format_session_ref(ResumeToken.t()) :: String.t()
  def format_session_ref(%ResumeToken{} = resume) do
    token = resume.value || ""
    abbreviated = if byte_size(token) > 40, do: String.slice(token, 0, 40) <> "…", else: token
    "#{resume.engine}: #{abbreviated}"
  end
end
