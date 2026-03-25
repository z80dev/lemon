defmodule LemonChannels.Adapters.Telegram.Transport.ModelPicker do
  @moduledoc """
  Telegram-local model picker flow extracted from the transport shell.

  This module owns the `/model` reply-keyboard conversation, provider/model
  pagination, selection state transitions, and model catalog lookup used by the
  Telegram adapter.
  """

  alias LemonChannels.Telegram.Delivery
  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.CallbackHandler
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonAiRuntime.Auth.OpenAICodexOAuth
  alias LemonCore.ChatScope
  alias LemonCore.Config
  alias LemonCore.MapHelpers
  alias LemonCore.Secrets

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
      current_future_model = default_model_preference(state, chat_id, thread_id)

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
            opts =
              %{
                "reply_to_message_id" => user_msg_id,
                "reply_markup" => callback_model_provider_markup(providers, 0)
              }
              |> maybe_put("message_thread_id", thread_id)

            _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
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
        case model_picker_key(inbound) do
          nil ->
            {state, false}

          key ->
            pickers = state.model_pickers || %{}

            case Map.get(pickers, key) do
              nil ->
                {state, false}

              picker ->
                handle_model_picker_input(state, inbound, key, picker, trimmed)
            end
        end
    end
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
        {drop_model_picker(state, key), false}
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
        case model_index_by_label(models, input) do
          nil ->
            {drop_model_picker(state, key), false}

          index ->
            case model_at_index(provider, index) do
              nil ->
                {drop_model_picker(state, key), false}

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
        {drop_model_picker(state, key), false}
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
          _ = put_default_model_preference(state, chat_id, thread_id, model_value)
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

  defp model_picker_overview_text(state, picker, chat_id, thread_id) do
    session_key = picker[:session_key]
    current_session_model = session_model_override(session_key)
    current_future_model = default_model_preference(state, chat_id, thread_id)
    render_model_picker_text(current_session_model, current_future_model)
  end

  defp model_picker_key(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    sender_id = inbound.sender && inbound.sender.id

    if is_integer(chat_id) and is_binary(sender_id) and sender_id != "" do
      {chat_id, thread_id, sender_id}
    else
      nil
    end
  rescue
    _ -> nil
  end

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

    _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
    :ok
  rescue
    _ -> :ok
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

  defp model_index_by_label(models, label) when is_list(models) and is_binary(label) do
    Enum.find_index(models, fn model ->
      model_label(model) == label
    end)
  end

  defp model_index_by_label(_models, _label), do: nil

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
    available_model_catalog()
    |> Enum.map(& &1.provider)
  end

  defp models_for_provider(provider) when is_binary(provider) do
    available_model_catalog()
    |> Enum.find_value([], fn
      %{provider: ^provider, models: models} -> models
      _ -> nil
    end)
  end

  defp model_at_index(provider, index)
       when is_binary(provider) and is_integer(index) and index >= 0 do
    models_for_provider(provider)
    |> Enum.at(index)
  end

  defp model_at_index(_provider, _index), do: nil

  defp model_spec(%{provider: provider, id: id}) when is_binary(provider) and is_binary(id) do
    "#{provider}:#{id}"
  end

  defp model_spec(_), do: nil

  defp model_label(%{name: name, id: id}) when is_binary(name) and name != "" and is_binary(id) do
    "#{name} (#{id})"
  end

  defp model_label(%{id: id}) when is_binary(id), do: id
  defp model_label(other), do: inspect(other)

  defp available_model_catalog do
    models_module = :"Elixir.Ai.Models"

    models =
      if Code.ensure_loaded?(models_module) and function_exported?(models_module, :list_models, 0) do
        apply(models_module, :list_models, [])
      else
        fallback_model_entries()
      end

    model_maps =
      models
      |> Enum.map(&to_model_map/1)
      |> Enum.filter(&is_map/1)

    filtered =
      model_maps
      |> filter_enabled_model_maps()
      |> maybe_fallback_to_default_providers(model_maps)

    filtered
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, provider_models} ->
      %{
        provider: provider,
        models:
          Enum.sort_by(provider_models, fn m ->
            {String.downcase(m.name || m.id || ""), m.id || ""}
          end)
      }
    end)
    |> Enum.sort_by(& &1.provider)
  rescue
    _ -> fallback_catalog()
  end

  defp to_model_map(%{provider: provider, id: id} = model) when is_binary(id) do
    provider_str = provider |> to_string() |> String.downcase()
    name = Map.get(model, :name) || Map.get(model, "name") || id
    %{provider: provider_str, id: id, name: name}
  rescue
    _ -> nil
  end

  defp to_model_map(_), do: nil

  defp fallback_model_entries do
    [
      %{provider: "anthropic", id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4"},
      %{provider: "openai", id: "gpt-4o", name: "GPT-4o"},
      %{provider: "google", id: "gemini-2.5-pro", name: "Gemini 2.5 Pro"}
    ]
  end

  defp fallback_catalog do
    fallback_model_entries()
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, models} -> %{provider: provider, models: models} end)
    |> Enum.sort_by(& &1.provider)
  end

  defp filter_enabled_model_maps(model_maps) when is_list(model_maps) do
    enabled = enabled_model_provider_names(model_maps)

    Enum.filter(model_maps, fn model ->
      normalize_provider_name(model.provider) in enabled
    end)
  end

  defp maybe_fallback_to_default_providers([], model_maps) when is_list(model_maps) do
    cfg = Config.cached()
    defaults = default_provider_hints(cfg)

    Enum.filter(model_maps, fn model ->
      normalize_provider_name(model.provider) in defaults
    end)
  rescue
    _ -> []
  end

  defp maybe_fallback_to_default_providers(filtered, _model_maps), do: filtered

  defp enabled_model_provider_names(model_maps) when is_list(model_maps) do
    cfg = Config.cached()
    configured = configured_provider_index(cfg)
    defaults = default_provider_hints(cfg)

    model_maps
    |> Enum.map(&normalize_provider_name(&1.provider))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.filter(fn provider ->
      provider_enabled?(provider, configured, defaults)
    end)
  rescue
    _ -> []
  end

  defp configured_provider_index(cfg) do
    providers = cfg.providers || %{}

    Enum.reduce(providers, %{}, fn {name, provider_cfg}, acc ->
      Map.put(acc, normalize_provider_name(name), provider_cfg || %{})
    end)
  rescue
    _ -> %{}
  end

  defp default_provider_hints(cfg) do
    agent = map_get(cfg, :agent) || %{}
    provider = map_get(agent, :default_provider)
    model = map_get(agent, :default_model)
    {model_provider, _model_id} = split_model_hint(model)

    [provider, model_provider]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&normalize_provider_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp provider_enabled?(provider, configured, defaults)
       when is_binary(provider) and is_map(configured) and is_list(defaults) do
    aliases = provider_aliases(provider)

    Enum.any?(aliases, &Map.has_key?(configured, &1)) or
      provider_has_credentials?(provider, aliases, configured) or
      Enum.any?(aliases, &(&1 in defaults)) or
      provider_special_enabled?(provider)
  end

  defp provider_enabled?(_provider, _configured, _defaults), do: false

  defp provider_has_credentials?(provider, aliases, configured) do
    configured_has_value? =
      Enum.any?(aliases, fn alias_name ->
        provider_cfg = Map.get(configured, alias_name, %{})

        present_value?(map_get(provider_cfg, :api_key)) or
          secret_present?(map_get(provider_cfg, :api_key_secret)) or
          present_value?(map_get(provider_cfg, :base_url))
      end)

    env_or_store_has_key? =
      provider_secret_candidates(provider, aliases)
      |> Enum.any?(&secret_present?/1)

    configured_has_value? or env_or_store_has_key?
  end

  defp provider_secret_candidates(provider, aliases) do
    generated =
      aliases
      |> Enum.map(&provider_to_env_prefix/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn prefix ->
        ["#{prefix}_API_KEY", "#{prefix}_TOKEN"]
      end)

    explicit =
      case provider do
        "anthropic" ->
          ["ANTHROPIC_API_KEY"]

        "openai" ->
          ["OPENAI_API_KEY"]

        "openai-codex" ->
          ["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"]

        "opencode" ->
          ["OPENCODE_API_KEY"]

        "google" ->
          ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

        "google-antigravity" ->
          ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

        "google-gemini-cli" ->
          ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

        "google-vertex" ->
          ["GOOGLE_APPLICATION_CREDENTIALS"]

        "amazon-bedrock" ->
          ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_PROFILE"]

        "kimi" ->
          ["KIMI_API_KEY", "MOONSHOT_API_KEY"]

        "kimi-coding" ->
          ["KIMI_API_KEY", "MOONSHOT_API_KEY"]

        "azure-openai-responses" ->
          ["AZURE_OPENAI_API_KEY"]

        _ ->
          []
      end

    (generated ++ explicit)
    |> Enum.flat_map(fn name -> [name, String.downcase(name)] end)
    |> Enum.uniq()
  end

  defp provider_special_enabled?("openai-codex"), do: openai_codex_auth_available?()

  defp provider_special_enabled?("amazon-bedrock"),
    do:
      (secret_present?("AWS_ACCESS_KEY_ID") and secret_present?("AWS_SECRET_ACCESS_KEY")) or
        secret_present?("AWS_PROFILE")

  defp provider_special_enabled?(_provider), do: false

  defp provider_aliases(provider) when is_binary(provider) do
    aliases =
      case normalize_provider_name(provider) do
        "google-antigravity" -> [provider, "google"]
        "google-gemini-cli" -> [provider, "google"]
        "google-vertex" -> [provider, "google"]
        "kimi-coding" -> [provider, "kimi"]
        "amazon-bedrock" -> [provider, "bedrock", "aws"]
        "azure-openai-responses" -> [provider, "azure-openai", "azure-openai-responses"]
        "minimax-cn" -> [provider, "minimax"]
        other -> [other]
      end

    aliases
    |> Enum.map(&normalize_provider_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp provider_aliases(_provider), do: []

  defp provider_to_env_prefix(provider) when is_binary(provider) do
    provider
    |> String.upcase()
    |> String.replace("-", "_")
    |> String.replace(~r/[^A-Z0-9_]/, "_")
    |> String.trim("_")
  rescue
    _ -> ""
  end

  defp provider_to_env_prefix(_provider), do: ""

  defp secret_present?(name) when is_binary(name) and name != "" do
    present_value?(System.get_env(name)) or
      present_value?(System.get_env(String.downcase(name))) or
      Secrets.exists?(name) or
      Secrets.exists?(String.downcase(name))
  rescue
    _ ->
      present_value?(System.get_env(name)) or
        present_value?(System.get_env(String.downcase(name)))
  end

  defp secret_present?(_), do: false

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(_), do: false

  defp openai_codex_auth_available?, do: OpenAICodexOAuth.available?()

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

  defp put_default_model_preference(state, chat_id, thread_id, model),
    do:
      ModelPolicyAdapter.put_default_model_preference(
        state.account_id || "default",
        chat_id,
        thread_id,
        model
      )

  defp normalize_provider_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.trim()
  rescue
    _ -> ""
  end

  defp split_model_hint(model_hint) when is_binary(model_hint) and model_hint != "" do
    case String.split(model_hint, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> {provider, model_id}
      _ -> {nil, model_hint}
    end
  end

  defp split_model_hint(_), do: {nil, nil}

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

  defp map_get(map, key), do: MapHelpers.get_key(map, key)

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
