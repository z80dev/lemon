defmodule LemonChannels.Adapters.Telegram.Transport.CallbackHandler do
  @moduledoc """
  Telegram-local callback query handler for inline keyboard actions.

  This module owns callback routing logic for cancel/model/approval/keepalive
  interactions so the transport shell stays focused on orchestration and state.
  """

  alias LemonChannels.BindingResolver
  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonCore.ChatScope
  alias LemonCore.Config
  alias LemonCore.MapHelpers
  alias LemonCore.SessionKey
  alias LemonCore.Secrets

  @idle_keepalive_continue_callback_prefix "lemon:idle:c:"
  @idle_keepalive_stop_callback_prefix "lemon:idle:k:"
  @cancel_callback_prefix "lemon:cancel"
  @model_callback_prefix "lemon:model"
  @providers_per_page 8
  @models_per_page 8
  @model_picker_prev "<< Prev"
  @model_picker_next "Next >>"
  @model_picker_back "< Back"
  @model_picker_close "Close"
  @model_picker_scope_session "This session"
  @model_picker_scope_future "All future sessions"

  def callback_model_provider_markup(providers, page) when is_list(providers) do
    model_provider_markup(providers, page)
  end

  def handle_callback_query(state, cb) when is_map(state) and is_map(cb) do
    cb_id = cb["id"]
    data = cb["data"] || ""

    cond do
      String.starts_with?(data, @idle_keepalive_continue_callback_prefix) ->
        run_id = String.trim_leading(data, @idle_keepalive_continue_callback_prefix)

        if is_binary(run_id) and run_id != "" and
             Code.ensure_loaded?(LemonChannels.Runtime) and
             function_exported?(LemonChannels.Runtime, :keep_run_alive, 2) do
          LemonChannels.Runtime.keep_run_alive(run_id, :continue)
        end

        _ = answer_callback_query(state, cb_id, "continuing...")
        maybe_close_callback_buttons(state, cb, "Continuing run.")
        :ok

      String.starts_with?(data, @idle_keepalive_stop_callback_prefix) ->
        run_id = String.trim_leading(data, @idle_keepalive_stop_callback_prefix)

        if is_binary(run_id) and run_id != "" and
             Code.ensure_loaded?(LemonChannels.Runtime) and
             function_exported?(LemonChannels.Runtime, :keep_run_alive, 2) do
          LemonChannels.Runtime.keep_run_alive(run_id, :cancel)
        end

        _ = answer_callback_query(state, cb_id, "stopping...")
        maybe_close_callback_buttons(state, cb, "Stopping run.")
        :ok

      String.starts_with?(data, @model_callback_prefix <> ":") ->
        _ = handle_model_callback_query(state, cb_id, cb, data)
        :ok

      data == @cancel_callback_prefix ->
        msg = cb["message"] || %{}
        chat_id = parse_int(get_in(msg, ["chat", "id"]))
        topic_id = parse_int(msg["message_thread_id"])
        message_id = parse_int(msg["message_id"])

        if is_integer(chat_id) and is_integer(message_id) do
          scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
          chat_type = get_in(msg, ["chat", "type"])
          peer_kind = peer_kind_from_chat_type(chat_type)

          session_key =
            lookup_session_key_for_reply(state, scope, message_id) ||
              SessionKey.channel_peer(%{
                agent_id: BindingResolver.resolve_agent_id(scope) || "default",
                channel_id: "telegram",
                account_id: state.account_id || "default",
                peer_kind: peer_kind,
                peer_id: to_string(chat_id),
                thread_id: if(is_integer(topic_id), do: to_string(topic_id), else: nil)
              })

          if Code.ensure_loaded?(LemonChannels.Runtime) and
               function_exported?(LemonChannels.Runtime, :cancel_by_progress_msg, 2) do
            LemonChannels.Runtime.cancel_by_progress_msg(session_key, message_id)
          end
        end

        _ = answer_callback_query(state, cb_id, "cancelling...")
        :ok

      String.starts_with?(data, @cancel_callback_prefix <> ":") ->
        run_id = String.trim_leading(data, @cancel_callback_prefix <> ":")

        if is_binary(run_id) and run_id != "" and
             Code.ensure_loaded?(LemonChannels.Runtime) and
             function_exported?(LemonChannels.Runtime, :cancel_by_run_id, 2) do
          LemonChannels.Runtime.cancel_by_run_id(run_id, :user_requested)
        end

        _ = answer_callback_query(state, cb_id, "cancelling...")
        :ok

      true ->
        {approval_id, decision} = parse_approval_callback(data)

        if is_binary(approval_id) and decision do
          _ = LemonCore.ExecApprovals.resolve(approval_id, decision)
          _ = answer_callback_query(state, cb_id, "Recorded")

          msg = cb["message"] || %{}
          chat_id = parse_int(get_in(msg, ["chat", "id"]))
          message_id = parse_int(msg["message_id"])

          if is_integer(chat_id) and is_integer(message_id) do
            _ =
              edit_message_text(
                state,
                chat_id,
                message_id,
                "Approval: #{decision_label(decision)}",
                %{"reply_markup" => %{"inline_keyboard" => []}}
              )
          end
        else
          _ = answer_callback_query(state, cb_id, "Unknown")
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  def handle_callback_query(_state, _cb), do: :ok

  defp handle_model_callback_query(state, cb_id, cb, data) do
    msg = cb["message"] || %{}
    chat_id = parse_int(get_in(msg, ["chat", "id"]))
    message_id = parse_int(msg["message_id"])
    topic_id = parse_int(msg["message_thread_id"])

    if not (is_integer(chat_id) and is_integer(message_id)) do
      _ = answer_callback_query(state, cb_id, "Unknown")
    else
      case parse_model_callback(data) do
        {:providers, page} ->
          providers = available_model_providers()

          _ =
            edit_message_text(
              state,
              chat_id,
              message_id,
              render_model_picker_text(nil, default_model_preference(state, chat_id, topic_id)),
              %{"reply_markup" => model_provider_markup(providers, page)}
            )

          _ = answer_callback_query(state, cb_id, "Updated")

        {:provider, provider, page} ->
          case models_for_provider(provider) do
            [] ->
              _ = answer_callback_query(state, cb_id, "No models")

            models ->
              _ =
                edit_message_text(
                  state,
                  chat_id,
                  message_id,
                  render_provider_models_text(provider),
                  %{"reply_markup" => model_list_markup(provider, models, page)}
                )

              _ = answer_callback_query(state, cb_id, "Updated")
          end

        {:choose, provider, index, page} ->
          case model_at_index(provider, index) do
            nil ->
              _ = answer_callback_query(state, cb_id, "Unknown model")

            model ->
              _ =
                edit_message_text(
                  state,
                  chat_id,
                  message_id,
                  render_model_scope_text(model),
                  %{"reply_markup" => model_scope_markup(provider, index, page)}
                )

              _ = answer_callback_query(state, cb_id, "Select scope")
          end

        {:set, scope, provider, index} ->
          case model_at_index(provider, index) do
            nil ->
              _ = answer_callback_query(state, cb_id, "Unknown model")

            model ->
              model_spec = model_spec(model)
              chat_scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

              session_key =
                SessionKey.channel_peer(%{
                  agent_id: BindingResolver.resolve_agent_id(chat_scope) || "default",
                  channel_id: "telegram",
                  account_id: state.account_id || "default",
                  peer_kind: peer_kind_from_chat_type(get_in(msg, ["chat", "type"])),
                  peer_id: to_string(chat_id),
                  thread_id: if(is_integer(topic_id), do: to_string(topic_id), else: nil)
                })

              _ = put_session_model_override(session_key, model_spec)

              if scope == :future do
                _ = put_default_model_preference(state, chat_id, topic_id, model_spec)
              end

              text =
                if scope == :future do
                  "Default model set to #{model_label(model)} for all future sessions in this chat."
                else
                  "Model set to #{model_label(model)} for this session."
                end

              _ =
                edit_message_text(
                  state,
                  chat_id,
                  message_id,
                  text,
                  %{"reply_markup" => %{"inline_keyboard" => []}}
                )

              _ = answer_callback_query(state, cb_id, "Saved")
          end

        :close ->
          _ =
            edit_message_text(state, chat_id, message_id, "Model picker closed.", %{
              "reply_markup" => %{"inline_keyboard" => []}
            })

          _ = answer_callback_query(state, cb_id, "Closed")

        _ ->
          _ = answer_callback_query(state, cb_id, "Unknown")
      end
    end

    :ok
  rescue
    _ ->
      _ = answer_callback_query(state, cb_id, "Unknown")
      :ok
  end

  defp parse_model_callback(data) when is_binary(data) do
    prefix = @model_callback_prefix <> ":"

    if String.starts_with?(data, prefix) do
      rest = String.replace_prefix(data, prefix, "")

      case String.split(rest, ":") do
        ["providers", page] ->
          {:providers, max(parse_int(page) || 0, 0)}

        ["provider", provider, page] ->
          {:provider, provider, max(parse_int(page) || 0, 0)}

        ["choose", provider, index, page] ->
          {:choose, provider, parse_int(index), max(parse_int(page) || 0, 0)}

        ["set", "s", provider, index] ->
          {:set, :session, provider, parse_int(index)}

        ["set", "f", provider, index] ->
          {:set, :future, provider, parse_int(index)}

        ["close"] ->
          :close

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_model_callback(_), do: nil

  defp parse_approval_callback(data) when is_binary(data) do
    case String.split(data, "|", parts: 2) do
      [approval_id, "once"] -> {approval_id, :approve_once}
      [approval_id, "session"] -> {approval_id, :approve_session}
      [approval_id, "agent"] -> {approval_id, :approve_agent}
      [approval_id, "global"] -> {approval_id, :approve_global}
      [approval_id, "deny"] -> {approval_id, :deny}
      _ -> {nil, nil}
    end
  end

  defp decision_label(:approve_once), do: "approve once"
  defp decision_label(:approve_session), do: "approve session"
  defp decision_label(:approve_agent), do: "approve agent"
  defp decision_label(:approve_global), do: "approve global"
  defp decision_label(:deny), do: "deny"
  defp decision_label(other), do: inspect(other)

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

  defp model_provider_markup(providers, page) when is_list(providers) do
    {slice, has_prev, has_next} = paginate(providers, page, @providers_per_page)

    rows =
      slice
      |> Enum.map(fn provider ->
        [%{"text" => provider, "callback_data" => model_callback_data(:provider, provider, page)}]
      end)
      |> maybe_add_pagination_row(has_prev, has_next, page, :providers)
      |> Kernel.++([[%{"text" => "Close", "callback_data" => model_callback_data(:close)}]])

    %{"inline_keyboard" => rows}
  end

  defp model_list_markup(provider, models, page) when is_binary(provider) and is_list(models) do
    indexed = Enum.with_index(models)
    {slice, has_prev, has_next} = paginate(indexed, page, @models_per_page)

    rows =
      slice
      |> Enum.map(fn {model, idx} ->
        [
          %{
            "text" => model_label(model),
            "callback_data" => model_callback_data(:choose, provider, idx, page)
          }
        ]
      end)
      |> maybe_add_pagination_row(has_prev, has_next, page, {:provider, provider})
      |> Kernel.++([
        [%{"text" => "Back", "callback_data" => model_callback_data(:providers, 0)}],
        [%{"text" => "Close", "callback_data" => model_callback_data(:close)}]
      ])

    %{"inline_keyboard" => rows}
  end

  defp model_scope_markup(provider, index, page)
       when is_binary(provider) and is_integer(index) and is_integer(page) do
    %{
      "inline_keyboard" => [
        [
          %{
            "text" => @model_picker_scope_session,
            "callback_data" => model_callback_data(:set, :session, provider, index)
          }
        ],
        [
          %{
            "text" => @model_picker_scope_future,
            "callback_data" => model_callback_data(:set, :future, provider, index)
          }
        ],
        [
          %{
            "text" => @model_picker_back,
            "callback_data" => model_callback_data(:provider, provider, page)
          }
        ],
        [%{"text" => @model_picker_close, "callback_data" => model_callback_data(:close)}]
      ]
    }
  end

  defp model_callback_data(:providers, page), do: "#{@model_callback_prefix}:providers:#{page}"

  defp model_callback_data(:provider, provider, page),
    do: "#{@model_callback_prefix}:provider:#{provider}:#{page}"

  defp model_callback_data(:choose, provider, index, page),
    do: "#{@model_callback_prefix}:choose:#{provider}:#{index}:#{page}"

  defp model_callback_data(:set, :session, provider, index),
    do: "#{@model_callback_prefix}:set:s:#{provider}:#{index}"

  defp model_callback_data(:set, :future, provider, index),
    do: "#{@model_callback_prefix}:set:f:#{provider}:#{index}"

  defp model_callback_data(:close), do: "#{@model_callback_prefix}:close"

  defp maybe_add_pagination_row(rows, has_prev, has_next, page, kind) do
    nav =
      []
      |> maybe_add_prev_button(has_prev, page, kind)
      |> maybe_add_next_button(has_next, page, kind)

    if nav == [] do
      rows
    else
      rows ++ [nav]
    end
  end

  defp maybe_add_prev_button(buttons, true, page, :providers) do
    buttons ++
      [
        %{
          "text" => @model_picker_prev,
          "callback_data" => model_callback_data(:providers, max(page - 1, 0))
        }
      ]
  end

  defp maybe_add_prev_button(buttons, true, page, {:provider, provider}) do
    buttons ++
      [
        %{
          "text" => @model_picker_prev,
          "callback_data" => model_callback_data(:provider, provider, max(page - 1, 0))
        }
      ]
  end

  defp maybe_add_prev_button(buttons, _has_prev, _page, _kind), do: buttons

  defp maybe_add_next_button(buttons, true, page, :providers) do
    buttons ++
      [
        %{
          "text" => @model_picker_next,
          "callback_data" => model_callback_data(:providers, page + 1)
        }
      ]
  end

  defp maybe_add_next_button(buttons, true, page, {:provider, provider}) do
    buttons ++
      [
        %{
          "text" => @model_picker_next,
          "callback_data" => model_callback_data(:provider, provider, page + 1)
        }
      ]
  end

  defp maybe_add_next_button(buttons, _has_next, _page, _kind), do: buttons

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
  end

  defp configured_provider_index(cfg) do
    providers = cfg.providers || %{}

    Enum.reduce(providers, %{}, fn {name, provider_cfg}, acc ->
      Map.put(acc, normalize_provider_name(name), provider_cfg || %{})
    end)
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

  defp openai_codex_auth_available? do
    mod = :"Elixir.Ai.Auth.OpenAICodexOAuth"

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_api_key, 0) do
      case apply(mod, :get_api_key, []) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp default_model_preference(state, chat_id, thread_id) do
    ModelPolicyAdapter.default_model_preference(state.account_id || "default", chat_id, thread_id)
  end

  defp put_session_model_override(session_key, model),
    do: ModelPolicyAdapter.put_session_model_override(session_key, model)

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
  end

  defp peer_kind_from_chat_type("private"), do: :dm
  defp peer_kind_from_chat_type("group"), do: :group
  defp peer_kind_from_chat_type("supergroup"), do: :group
  defp peer_kind_from_chat_type("channel"), do: :channel
  defp peer_kind_from_chat_type(_), do: :unknown

  defp split_model_hint(model_hint) when is_binary(model_hint) and model_hint != "" do
    case String.split(model_hint, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> {provider, model_id}
      _ -> {nil, model_hint}
    end
  end

  defp split_model_hint(_), do: {nil, nil}

  defp map_get(map, key), do: MapHelpers.get_key(map, key)

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(_), do: false

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

  defp lookup_session_key_for_reply(state, %ChatScope{} = scope, reply_to_id)
       when is_integer(reply_to_id) do
    SessionRouting.lookup_session_key_for_reply(
      state.account_id || "default",
      scope,
      reply_to_id,
      PerChatState.current_thread_generation(
        state.account_id || "default",
        scope.chat_id,
        scope.topic_id
      )
    )
  end

  defp lookup_session_key_for_reply(_state, _scope, _reply_to_id), do: nil

  defp edit_message_text(state, chat_id, message_id, text, opts) do
    state.api_mod.edit_message_text(state.token, chat_id, message_id, text, opts)
  end

  defp answer_callback_query(state, cb_id, text_or_opts) when is_binary(text_or_opts) do
    state.api_mod.answer_callback_query(state.token, cb_id, %{"text" => text_or_opts})
  end

  defp answer_callback_query(state, cb_id, opts) when is_map(opts) do
    state.api_mod.answer_callback_query(state.token, cb_id, opts)
  end

  defp maybe_close_callback_buttons(state, cb, replacement_text) do
    msg = cb["message"] || %{}
    chat_id = parse_int(get_in(msg, ["chat", "id"]))
    message_id = parse_int(msg["message_id"])

    if is_integer(chat_id) and is_integer(message_id) and is_binary(replacement_text) do
      _ =
        edit_message_text(
          state,
          chat_id,
          message_id,
          replacement_text,
          %{"reply_markup" => %{"inline_keyboard" => []}}
        )
    end

    :ok
  rescue
    _ -> :ok
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
end
