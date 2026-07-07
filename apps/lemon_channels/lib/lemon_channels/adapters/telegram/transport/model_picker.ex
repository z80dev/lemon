defmodule LemonChannels.Adapters.Telegram.Transport.ModelPicker do
  @moduledoc """
  Telegram-local model picker flow extracted from the transport shell.

  This module owns the `/model` reply-keyboard conversation, provider/model
  pagination, selection state transitions, and model catalog lookup used by the
  Telegram adapter.
  """

  alias AgentCore.ModelRuntime.ModelCatalog
  alias LemonChannels.Telegram.Delivery
  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.CallbackHandler
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonCore.ChatScope
  alias LemonChannels.Telegram.API, as: TelegramAPI

  @providers_per_page 8
  @models_per_page 8
  @model_picker_prev "<< Prev"
  @model_picker_next "Next >>"
  @model_picker_back "< Back"
  @model_picker_close "Close"
  @model_picker_scope_session "This session"
  @model_picker_scope_future "All future sessions"

  def handle_model_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    state = MessageBuffer.drop_buffer_for(state, inbound)

    if not is_integer(chat_id) do
      state
    else
      providers = available_model_providers()

      session_key =
        build_session_key(state, inbound, %ChatScope{
          transport: :telegram,
          chat_id: chat_id,
          topic_id: thread_id
        })

      current_session_model = session_model_override(session_key)
      current_future_model = chat_default_model_preference(state, chat_id)

      text = render_model_picker_text(current_session_model, current_future_model)
      picker_key = model_picker_key(inbound)

      if providers == [] do
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text <> "\n\nNo models available."
          )

        if picker_key, do: drop_model_picker(state, picker_key), else: state
      else
        cond do
          picker_key ->
            picker = %{
              step: :provider,
              provider_page: 0,
              provider: nil,
              model_page: 0,
              model_index: nil,
              session_key: session_key
            }

            state = put_model_picker(state, picker_key, picker)

            _ =
              send_model_picker_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                text,
                model_provider_reply_markup(providers, 0)
              )

            state

          true ->
            _ =
              send_model_picker_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                text,
                callback_model_provider_markup(providers, 0)
              )

            state
        end
      end
    end
  rescue
    _ -> state
  end

  def maybe_handle_model_picker_input(state, inbound, text) do
    trimmed = String.trim(text || "")

    cond do
      trimmed == "" ->
        {state, false}

      Commands.command_message?(trimmed) ->
        {state, false}

      true ->
        pickers = state.model_pickers || %{}

        case lookup_model_picker(pickers, inbound) do
          nil ->
            {state, false}

          {key, picker} ->
            case safe_handle_model_picker_input(state, inbound, key, picker, trimmed) do
              {:ok, {next_state, true}} ->
                {next_state, true}

              {:ok, {_next_state, false}} ->
                consume_invalid_model_picker_input(state, inbound, key, picker)

              {:error, _reason} ->
                consume_invalid_model_picker_input(state, inbound, key, picker)
            end
        end
    end
  rescue
    _ -> {state, false}
  end

  defp safe_handle_model_picker_input(state, inbound, key, picker, trimmed) do
    {:ok, handle_model_picker_input(state, inbound, key, picker, trimmed)}
  rescue
    error -> {:error, error}
  end

  defp lookup_model_picker(pickers, inbound) when is_map(pickers) do
    case model_picker_key(inbound) do
      nil ->
        scope_model_picker(pickers, inbound)

      key ->
        case Map.fetch(pickers, key) do
          {:ok, picker} -> {key, picker}
          :error -> scope_model_picker(pickers, inbound)
        end
    end
  end

  defp lookup_model_picker(_pickers, _inbound), do: nil

  defp scope_model_picker(pickers, inbound) when is_map(pickers) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)

    pickers
    |> Enum.filter(fn
      {{picker_chat_id, picker_thread_id, _sender_id}, _picker} ->
        picker_chat_id == chat_id and picker_thread_id == thread_id

      _ ->
        false
    end)
    |> case do
      [{key, picker}] -> {key, picker}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp consume_invalid_model_picker_input(state, inbound, key, picker) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    state = put_model_picker(state, key, picker)

    case picker[:step] do
      :provider ->
        providers = available_model_providers()

        text =
          invalid_picker_selection_text(
            "Unknown provider selection. Use one of the buttons.",
            model_picker_overview_text(state, picker, chat_id, thread_id)
          )

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_provider_reply_markup(providers, picker[:provider_page] || 0)
          )

      :model ->
        provider = picker[:provider]
        models = models_for_provider(provider)

        text =
          invalid_picker_selection_text(
            "Unknown model selection. Use one of the buttons.",
            render_provider_models_text(provider)
          )

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_list_reply_markup(provider, models, picker[:model_page] || 0)
          )

      :scope ->
        provider = picker[:provider]
        model = model_at_index(provider, picker[:model_index] || -1)

        text =
          invalid_picker_selection_text(
            "Choose one of the scope buttons.",
            render_model_scope_text(model)
          )

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_scope_reply_markup()
          )

      _ ->
        :ok
    end

    {state, true}
  rescue
    _ -> {state, false}
  end

  defp handle_model_picker_input(state, inbound, key, picker, input) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    providers = available_model_providers()

    case picker[:step] do
      :provider ->
        handle_model_picker_provider_step(
          state,
          key,
          picker,
          providers,
          chat_id,
          thread_id,
          user_msg_id,
          input
        )

      :model ->
        handle_model_picker_model_step(state, key, picker, chat_id, thread_id, user_msg_id, input)

      :scope ->
        handle_model_picker_scope_step(state, key, picker, chat_id, thread_id, user_msg_id, input)

      _ ->
        {drop_model_picker(state, key), false}
    end
  end

  defp handle_model_picker_provider_step(
         state,
         key,
         picker,
         providers,
         chat_id,
         thread_id,
         user_msg_id,
         input
       ) do
    page = picker[:provider_page] || 0

    cond do
      model_picker_close?(input) ->
        state = drop_model_picker(state, key)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Model picker closed.",
            model_picker_remove_markup()
          )

        {state, true}

      model_picker_prev?(input) ->
        new_page = max(page - 1, 0)
        picker = Map.put(picker, :provider_page, new_page)
        state = put_model_picker(state, key, picker)
        text = model_picker_overview_text(state, picker, chat_id, thread_id)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_provider_reply_markup(providers, new_page)
          )

        {state, true}

      model_picker_next?(input) ->
        new_page = min(page + 1, max_page_for(providers, @providers_per_page))
        picker = Map.put(picker, :provider_page, new_page)
        state = put_model_picker(state, key, picker)
        text = model_picker_overview_text(state, picker, chat_id, thread_id)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_provider_reply_markup(providers, new_page)
          )

        {state, true}

      input in providers ->
        models = models_for_provider(input)

        if models == [] do
          _ =
            send_model_picker_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Provider: #{input}\nNo models are currently available.",
              model_provider_reply_markup(providers, page)
            )

          {state, true}
        else
          picker =
            picker
            |> Map.put(:step, :model)
            |> Map.put(:provider, input)
            |> Map.put(:model_page, 0)

          state = put_model_picker(state, key, picker)

          _ =
            send_model_picker_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_provider_models_text(input),
              model_list_reply_markup(input, models, 0)
            )

          {state, true}
        end

      true ->
        text =
          invalid_picker_selection_text(
            "Unknown provider selection. Use one of the buttons.",
            model_picker_overview_text(state, picker, chat_id, thread_id)
          )

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_provider_reply_markup(providers, page)
          )

        {state, true}
    end
  end

  defp handle_model_picker_model_step(state, key, picker, chat_id, thread_id, user_msg_id, input) do
    provider = picker[:provider]
    page = picker[:model_page] || 0
    models = models_for_provider(provider)

    cond do
      model_picker_close?(input) ->
        state = drop_model_picker(state, key)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Model picker closed.",
            model_picker_remove_markup()
          )

        {state, true}

      model_picker_back?(input) ->
        provider_page = picker[:provider_page] || 0
        providers = available_model_providers()

        picker =
          picker
          |> Map.put(:step, :provider)
          |> Map.put(:provider, nil)
          |> Map.put(:provider_page, provider_page)

        state = put_model_picker(state, key, picker)
        text = model_picker_overview_text(state, picker, chat_id, thread_id)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_provider_reply_markup(providers, provider_page)
          )

        {state, true}

      model_picker_prev?(input) ->
        new_page = max(page - 1, 0)
        picker = Map.put(picker, :model_page, new_page)
        state = put_model_picker(state, key, picker)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            render_provider_models_text(provider),
            model_list_reply_markup(provider, models, new_page)
          )

        {state, true}

      model_picker_next?(input) ->
        new_page = min(page + 1, max_page_for(models, @models_per_page))
        picker = Map.put(picker, :model_page, new_page)
        state = put_model_picker(state, key, picker)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            render_provider_models_text(provider),
            model_list_reply_markup(provider, models, new_page)
          )

        {state, true}

      true ->
        case model_index_by_input(provider, models, input) do
          nil ->
            text =
              invalid_picker_selection_text(
                "Unknown model selection. Use one of the buttons.",
                render_provider_models_text(provider)
              )

            _ =
              send_model_picker_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                text,
                model_list_reply_markup(provider, models, page)
              )

            {state, true}

          index ->
            case model_at_index(provider, index) do
              nil ->
                text =
                  invalid_picker_selection_text(
                    "Unknown model selection. Use one of the buttons.",
                    render_provider_models_text(provider)
                  )

                _ =
                  send_model_picker_message(
                    state,
                    chat_id,
                    thread_id,
                    user_msg_id,
                    text,
                    model_list_reply_markup(provider, models, page)
                  )

                {state, true}

              model ->
                picker =
                  picker
                  |> Map.put(:step, :scope)
                  |> Map.put(:model_index, index)
                  |> Map.put(:model_page, div(index, @models_per_page))

                state = put_model_picker(state, key, picker)

                _ =
                  send_model_picker_message(
                    state,
                    chat_id,
                    thread_id,
                    user_msg_id,
                    render_model_scope_text(model),
                    model_scope_reply_markup()
                  )

                {state, true}
            end
        end
    end
  end

  defp handle_model_picker_scope_step(state, key, picker, chat_id, thread_id, user_msg_id, input) do
    provider = picker[:provider]
    model_page = picker[:model_page] || 0

    cond do
      model_picker_close?(input) ->
        state = drop_model_picker(state, key)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Model picker closed.",
            model_picker_remove_markup()
          )

        {state, true}

      model_picker_back?(input) ->
        models = models_for_provider(provider)

        picker =
          picker
          |> Map.put(:step, :model)
          |> Map.put(:model_page, model_page)

        state = put_model_picker(state, key, picker)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            render_provider_models_text(provider),
            model_list_reply_markup(provider, models, model_page)
          )

        {state, true}

      model_picker_scope_session?(input) ->
        apply_model_picker_selection(
          state,
          key,
          picker,
          :session,
          chat_id,
          thread_id,
          user_msg_id
        )

      model_picker_scope_future?(input) ->
        apply_model_picker_selection(
          state,
          key,
          picker,
          :future,
          chat_id,
          thread_id,
          user_msg_id
        )

      true ->
        model = model_at_index(provider, picker[:model_index])

        text =
          invalid_picker_selection_text(
            "Choose one of the scope buttons.",
            render_model_scope_text(model)
          )

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_scope_reply_markup()
          )

        {state, true}
    end
  end

  defp apply_model_picker_selection(state, key, picker, scope, chat_id, thread_id, user_msg_id) do
    provider = picker[:provider]
    index = picker[:model_index]

    case model_at_index(provider, index) do
      nil ->
        {drop_model_picker(state, key), false}

      model ->
        model_value = model_spec(model)
        session_key = picker[:session_key]

        _ = put_session_model_override(session_key, model_value)

        if scope == :future do
          _ = put_default_model_preference(state, chat_id, nil, model_value)
        end

        text =
          if scope == :future do
            "Default model set to #{model_label(model)} for all future sessions in this chat."
          else
            "Model set to #{model_label(model)} for this session."
          end

        state = drop_model_picker(state, key)

        _ =
          send_model_picker_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            text,
            model_picker_remove_markup()
          )

        {state, true}
    end
  end

  defp model_picker_overview_text(state, picker, chat_id, _thread_id) do
    session_key = picker[:session_key]
    current_session_model = session_model_override(session_key)
    current_future_model = chat_default_model_preference(state, chat_id)
    render_model_picker_text(current_session_model, current_future_model)
  end

  defp model_picker_key(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    sender_id = normalize_sender_id(inbound.sender && inbound.sender.id)

    if is_integer(chat_id) and not is_nil(sender_id) do
      {chat_id, thread_id, sender_id}
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp normalize_sender_id(id) when is_integer(id), do: Integer.to_string(id)

  defp normalize_sender_id(id) when is_binary(id) do
    trimmed = String.trim(id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_sender_id(_), do: nil

  defp put_model_picker(state, key, picker) when is_map(picker) do
    put_in(state, [:model_pickers], Map.put(state.model_pickers || %{}, key, picker))
  end

  defp drop_model_picker(state, key) do
    put_in(state, [:model_pickers], Map.delete(state.model_pickers || %{}, key))
  end

  defp send_model_picker_message(
         state,
         chat_id,
         thread_id,
         reply_to_message_id,
         text,
         reply_markup
       )
       when is_integer(chat_id) and is_binary(text) and is_map(reply_markup) do
    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", thread_id)
      |> maybe_put("reply_markup", reply_markup)

    if use_outbox_delivery?(state) do
      delivery_opts =
        []
        |> maybe_put_kw(:account_id, state.account_id || "default")
        |> maybe_put_kw(:thread_id, thread_id)
        |> maybe_put_kw(:reply_to_message_id, reply_to_message_id)
        |> maybe_put_kw(:reply_markup, reply_markup)

      case Delivery.enqueue_send(chat_id, text, delivery_opts) do
        :ok ->
          :ok

        {:error, _reason} ->
          _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
          :ok
      end
    else
      _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
      :ok
    end
  rescue
    _ -> :ok
  end

  defp use_outbox_delivery?(state) do
    state.api_mod == TelegramAPI
  end

  defp model_provider_reply_markup(providers, page) when is_list(providers) do
    {slice, has_prev, has_next} = paginate(providers, page, @providers_per_page)

    rows =
      slice
      |> Enum.chunk_every(2)
      |> Enum.map(fn chunk ->
        Enum.map(chunk, &%{"text" => &1})
      end)
      |> maybe_add_reply_pagination_row(has_prev, has_next)
      |> Kernel.++([[%{"text" => @model_picker_close}]])

    %{
      "keyboard" => rows,
      "resize_keyboard" => true,
      "one_time_keyboard" => true
    }
  end

  defp model_list_reply_markup(_provider, models, page) when is_list(models) do
    indexed = Enum.with_index(models)
    {slice, has_prev, has_next} = paginate(indexed, page, @models_per_page)

    rows =
      slice
      |> Enum.map(fn {model, _idx} -> [%{"text" => model_label(model)}] end)
      |> maybe_add_reply_pagination_row(has_prev, has_next)
      |> Kernel.++([[%{"text" => @model_picker_back}, %{"text" => @model_picker_close}]])

    %{
      "keyboard" => rows,
      "resize_keyboard" => true,
      "one_time_keyboard" => true
    }
  end

  defp model_scope_reply_markup do
    %{
      "keyboard" => [
        [%{"text" => @model_picker_scope_session}],
        [%{"text" => @model_picker_scope_future}],
        [%{"text" => @model_picker_back}, %{"text" => @model_picker_close}]
      ],
      "resize_keyboard" => true,
      "one_time_keyboard" => true
    }
  end

  defp model_picker_remove_markup do
    %{"remove_keyboard" => true}
  end

  defp invalid_picker_selection_text(error_text, body)
       when is_binary(error_text) and is_binary(body) do
    error_text <> "\n\n" <> body
  end

  defp maybe_add_reply_pagination_row(rows, has_prev, has_next) do
    nav =
      []
      |> maybe_add_reply_prev(has_prev)
      |> maybe_add_reply_next(has_next)

    if nav == [] do
      rows
    else
      rows ++ [nav]
    end
  end

  defp maybe_add_reply_prev(buttons, true), do: buttons ++ [%{"text" => @model_picker_prev}]
  defp maybe_add_reply_prev(buttons, _), do: buttons

  defp maybe_add_reply_next(buttons, true), do: buttons ++ [%{"text" => @model_picker_next}]
  defp maybe_add_reply_next(buttons, _), do: buttons

  defp model_picker_prev?(text), do: picker_text_eq?(text, @model_picker_prev)
  defp model_picker_next?(text), do: picker_text_eq?(text, @model_picker_next)
  defp model_picker_back?(text), do: picker_text_eq?(text, @model_picker_back)
  defp model_picker_close?(text), do: picker_text_eq?(text, @model_picker_close)

  defp model_picker_scope_session?(text), do: picker_text_eq?(text, @model_picker_scope_session)
  defp model_picker_scope_future?(text), do: picker_text_eq?(text, @model_picker_scope_future)

  defp picker_text_eq?(left, right)
       when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp picker_text_eq?(_left, _right), do: false

  defp model_index_by_input(provider, models, input)
       when is_binary(provider) and is_list(models) and is_binary(input) do
    normalized = normalize_model_picker_input(input)

    Enum.find_index(models, fn model ->
      normalized in model_picker_inputs(provider, model)
    end)
  end

  defp model_index_by_input(_provider, _models, _input), do: nil

  defp model_picker_inputs(provider, %{id: id} = model)
       when is_binary(provider) and is_binary(id) do
    [
      model_label(model),
      id,
      "#{provider}:#{id}",
      Map.get(model, :name),
      Map.get(model, "name")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_model_picker_input/1)
  end

  defp model_picker_inputs(_provider, model) do
    [model_label(model)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_model_picker_input/1)
  end

  defp normalize_model_picker_input(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_model_picker_input(_value), do: nil

  defp max_page_for(list, per_page)
       when is_list(list) and is_integer(per_page) and per_page > 0 do
    case length(list) do
      0 -> 0
      n -> div(n - 1, per_page)
    end
  end

  defp render_model_picker_text(session_model, future_model) do
    session_line = if is_binary(session_model), do: session_model, else: "(not set)"
    future_line = if is_binary(future_model), do: future_model, else: "(not set)"

    [
      "Model picker",
      "",
      "Session model: #{session_line}",
      "Future default: #{future_line}",
      "",
      "Choose a provider:"
    ]
    |> Enum.join("\n")
  end

  defp render_provider_models_text(provider) when is_binary(provider) do
    "Provider: #{provider}\nChoose a model:"
  end

  defp render_model_scope_text(model) do
    "Selected model: #{model_label(model)}\nApply to:"
  end

  defp paginate(list, page, per_page)
       when is_list(list) and is_integer(page) and is_integer(per_page) do
    p = if page < 0, do: 0, else: page
    start_index = p * per_page
    total = length(list)
    slice = list |> Enum.drop(start_index) |> Enum.take(per_page)
    has_prev = p > 0
    has_next = start_index + per_page < total
    {slice, has_prev, has_next}
  end

  defp available_model_providers do
    ModelCatalog.providers(available_model_catalog())
  end

  defp models_for_provider(provider) when is_binary(provider) do
    ModelCatalog.models_for_provider(available_model_catalog(), provider)
  end

  defp model_at_index(provider, index) do
    ModelCatalog.model_at_index(available_model_catalog(), provider, index)
  end

  defp model_spec(model), do: ModelCatalog.model_spec(model)

  defp model_label(model), do: ModelCatalog.model_label(model)

  defp available_model_catalog, do: ModelCatalog.available_catalog()

  defp session_model_override(session_key),
    do: ModelPolicyAdapter.session_model_override(session_key)

  defp put_session_model_override(session_key, model),
    do: ModelPolicyAdapter.put_session_model_override(session_key, model)

  defp default_model_preference(state, chat_id, thread_id),
    do:
      ModelPolicyAdapter.default_model_preference(
        state.account_id || "default",
        chat_id,
        thread_id
      )

  defp chat_default_model_preference(state, chat_id),
    do: default_model_preference(state, chat_id, nil)

  defp put_default_model_preference(state, chat_id, thread_id, model),
    do:
      ModelPolicyAdapter.put_default_model_preference(
        state.account_id || "default",
        chat_id,
        thread_id,
        model
      )

  defp build_session_key(state, inbound, %ChatScope{} = scope) do
    SessionRouting.build_session_key(state.account_id || "default", inbound, scope)
  end

  defp extract_message_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)
    {chat_id, thread_id, user_msg_id}
  end

  defp send_system_message(state, chat_id, thread_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    delivery_opts =
      []
      |> maybe_put_kw(:account_id, state.account_id || "default")
      |> maybe_put_kw(:thread_id, thread_id)
      |> maybe_put_kw(:reply_to_message_id, reply_to_message_id)

    case Delivery.enqueue_send(chat_id, text, delivery_opts) do
      :ok ->
        :ok

      {:error, _reason} ->
        opts =
          %{}
          |> maybe_put("reply_to_message_id", reply_to_message_id)
          |> maybe_put("message_thread_id", thread_id)

        _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp callback_model_provider_markup(providers, page) when is_list(providers) do
    CallbackHandler.callback_model_provider_markup(providers, page)
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(opts, _key, nil) when is_list(opts), do: opts

  defp maybe_put_kw(opts, key, value) when is_list(opts) do
    [{key, value} | opts]
  end
end
