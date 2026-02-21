defmodule LemonGateway.Transports.Farcaster.CastHandler do
  @moduledoc """
  Processes Farcaster frame actions by verifying trusted data, resolving
  sessions, submitting prompts to the runtime, and building the response
  HTML with frame metadata (image, buttons, state).
  """

  require Logger

  alias LemonGateway.{BindingResolver, Runtime, Store}
  alias LemonGateway.Transports.Farcaster.HubClient
  alias LemonGateway.Types.{ChatScope, Job}
  alias LemonCore.SessionKey

  @default_action_path "/frames/farcaster/actions"
  @default_image_url "https://placehold.co/1200x630/png?text=Lemon+Farcaster"
  @default_input_label "Send a prompt to Lemon"
  @default_account_id "default"
  @max_state_prompt_length 280
  @max_frame_state_json_length 1024
  @max_frame_state_value_length 256
  @max_frame_input_label_length 64
  @max_frame_button_label_length 32
  @max_frame_status_length 160
  @max_session_component_length 96
  @session_table :farcaster_frame_sessions

  @spec action_path() :: String.t()
  def action_path do
    config()
    |> Map.get(:action_path)
    |> normalize_path()
  end

  @spec initial_frame(String.t()) :: String.t()
  def initial_frame(request_url) when is_binary(request_url) do
    session_ref = new_session_ref()

    frame_html(
      %{
        "session_ref" => session_ref,
        "status" => "ready"
      },
      "Frame ready. Enter a prompt.",
      request_url
    )
  end

  @spec handle_action(map(), String.t()) :: String.t()
  def handle_action(params, request_url) when is_map(params) and is_binary(request_url) do
    with {:ok, action} <- normalize_action(params),
         :ok <- maybe_verify_trusted_data(action),
         {:ok, outcome} <- process_action(action) do
      frame_html(
        %{
          "session_ref" => outcome.session_ref,
          "fid" => action.fid,
          "last_prompt" => truncate_state_prompt(outcome.prompt),
          "last_run_id" => outcome.run_id,
          "status" => outcome.status
        },
        outcome.message,
        request_url
      )
    else
      {:error, reason} ->
        Logger.warning("farcaster frame action rejected: #{inspect(reason)}")

        frame_html(
          %{
            "session_ref" => new_session_ref(),
            "status" => "error"
          },
          "Unable to process frame action.",
          request_url
        )
    end
  rescue
    error ->
      Logger.warning("farcaster frame action failed: #{inspect(error)}")

      frame_html(
        %{
          "session_ref" => new_session_ref(),
          "status" => "error"
        },
        "Unexpected frame error.",
        request_url
      )
  end

  defp process_action(action) do
    with {:ok, scope} <- build_scope(action) do
      previous_ref = current_session_ref(action, scope.chat_id)
      new_session? = action.button_index == 2

      session_ref =
        if new_session?, do: new_session_ref(), else: previous_ref || new_session_ref()

      session_key = build_session_key(scope, session_ref)

      if new_session? and is_binary(previous_ref) and previous_ref != session_ref do
        delete_session(scope, previous_ref)
      end

      persist_session(scope.chat_id, session_ref)

      case resolve_prompt(action, new_session?) do
        nil ->
          status = if new_session?, do: "new_session", else: "waiting_input"
          message = if new_session?, do: "Started a fresh session.", else: "Enter a prompt."

          {:ok,
           %{
             session_ref: session_ref,
             session_key: session_key,
             run_id: nil,
             prompt: "",
             status: status,
             message: message
           }}

        prompt ->
          {engine_hint, prompt} = LemonGateway.EngineDirective.strip(prompt)

          case submit_job(scope, session_key, session_ref, prompt, engine_hint, action) do
            {:ok, run_id} ->
              {:ok,
               %{
                 session_ref: session_ref,
                 session_key: session_key,
                 run_id: run_id,
                 prompt: prompt,
                 status: "queued",
                 message: "Queued run #{run_id}"
               }}

            {:error, _reason} ->
              {:ok,
               %{
                 session_ref: session_ref,
                 session_key: session_key,
                 run_id: nil,
                 prompt: prompt,
                 status: "error",
                 message: "Failed to queue run."
               }}
          end
      end
    end
  end

  defp submit_job(scope, session_key, session_ref, prompt, engine_hint, action) do
    run_id = LemonCore.Id.run_id()
    engine_id = BindingResolver.resolve_engine(scope, engine_hint, nil)

    job = %Job{
      run_id: run_id,
      session_key: session_key,
      prompt: prompt,
      engine_id: engine_id,
      cwd: BindingResolver.resolve_cwd(scope),
      queue_mode: BindingResolver.resolve_queue_mode(scope) || :collect,
      meta: %{
        origin: :farcaster,
        farcaster: %{
          fid: scope.chat_id,
          button_index: action.button_index,
          cast_hash: action.cast_hash,
          session_ref: session_ref,
          session_key: session_key
        }
      }
    }

    Runtime.submit(job)
    {:ok, run_id}
  rescue
    error ->
      Logger.warning("farcaster submit failed: #{inspect(error)}")
      {:error, error}
  end

  defp resolve_prompt(action, new_session?) do
    input = normalize_blank(action.input_text)

    cond do
      is_binary(input) ->
        input

      action.button_index == 1 ->
        case action.state
             |> get_in(["last_prompt"])
             |> normalize_blank()
             |> truncate_state_prompt() do
          value when is_binary(value) -> value
          _ -> "continue"
        end

      action.button_index == 2 and new_session? ->
        nil

      true ->
        nil
    end
  end

  defp current_session_ref(action, chat_id) do
    from_state = verified_state_session_ref(action.state)

    cond do
      is_binary(from_state) ->
        from_state

      is_integer(chat_id) and chat_id > 0 ->
        case Store.get(@session_table, chat_id) do
          %{"session_ref" => ref} when is_binary(ref) and ref != "" -> ref
          %{session_ref: ref} when is_binary(ref) and ref != "" -> ref
          _ -> nil
        end

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp persist_session(chat_id, session_ref) when is_integer(chat_id) and chat_id > 0 do
    Store.put(@session_table, chat_id, %{
      "session_ref" => session_ref,
      "updated_at_ms" => System.system_time(:millisecond)
    })
  rescue
    _ -> :ok
  end

  defp persist_session(_, _), do: :ok

  defp delete_session(scope, session_ref) do
    old_key = build_session_key(scope, session_ref)
    Store.delete_chat_state(old_key)
  rescue
    _ -> :ok
  end

  defp build_scope(%{fid: fid}) when is_integer(fid) and fid > 0 do
    {:ok, %ChatScope{transport: :farcaster, chat_id: fid, topic_id: nil}}
  end

  defp build_scope(_), do: {:error, :invalid_fid}

  defp build_session_key(%ChatScope{} = scope, session_ref) do
    agent_id = sanitize_session_component(BindingResolver.resolve_agent_id(scope), "default")
    account_id = sanitize_session_component(farcaster_account_id(), @default_account_id)
    peer_id = sanitize_session_component(Integer.to_string(scope.chat_id), "0")
    sub_id = sanitize_session_component(session_ref, "default")

    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "farcaster",
      account_id: account_id,
      peer_kind: :dm,
      peer_id: peer_id,
      sub_id: sub_id
    })
  end

  defp frame_html(state, status_text, request_url) do
    status_text = clip_frame_meta(status_text, @max_frame_status_length)

    state =
      state
      |> stringify_keys()
      |> with_signed_session_ref()

    state_json = encode_state(state)
    post_url = frame_post_url(request_url)
    image_url = frame_image_url(state, status_text)

    input_label =
      (normalize_blank(config()[:input_label]) || @default_input_label)
      |> clip_frame_meta(@max_frame_input_label_length)

    button_1 =
      (normalize_blank(config()[:button_1]) || "Send")
      |> clip_frame_meta(@max_frame_button_label_length)

    button_2 =
      (normalize_blank(config()[:button_2]) || "New Session")
      |> clip_frame_meta(@max_frame_button_label_length)

    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta property="fc:frame" content="vNext" />
        <meta property="fc:frame:image" content="#{html_escape(image_url)}" />
        <meta property="fc:frame:post_url" content="#{html_escape(post_url)}" />
        <meta property="fc:frame:state" content="#{html_escape(state_json)}" />
        <meta property="fc:frame:input:text" content="#{html_escape(input_label)}" />
        <meta property="fc:frame:button:1" content="#{html_escape(button_1)}" />
        <meta property="fc:frame:button:2" content="#{html_escape(button_2)}" />
      </head>
      <body>
        <p>#{html_escape(status_text)}</p>
      </body>
    </html>
    """
  end

  defp frame_post_url(request_url) do
    case normalize_blank(config()[:frame_base_url]) do
      nil ->
        request_url

      base ->
        build_public_url(base, action_path()) || request_url
    end
  end

  defp frame_image_url(state, status_text) do
    session_ref = normalize_blank(get_in(state, ["session_ref"]))
    base = normalize_blank(config()[:image_url]) || @default_image_url

    append_query(base, %{
      "session_ref" => session_ref,
      "status" => status_text
    })
  end

  defp append_query(url, params) when is_binary(url) do
    params =
      params
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    if map_size(params) == 0 do
      url
    else
      uri = URI.parse(url)
      existing = URI.decode_query(uri.query || "")
      query = Map.merge(existing, params) |> URI.encode_query()
      URI.to_string(%{uri | query: query})
    end
  rescue
    _ -> url
  end

  defp append_query(url, _params), do: url

  defp encode_state(state) when is_map(state) do
    encoded_state =
      state
      |> clip_state_values()
      |> do_encode_state()

    case encoded_state do
      json when is_binary(json) and byte_size(json) <= @max_frame_state_json_length ->
        json

      _ ->
        compact_state =
          state
          |> Map.take(["session_ref", "session_sig", "status", "fid", "last_run_id"])
          |> clip_state_values()

        case do_encode_state(compact_state) do
          json when is_binary(json) and byte_size(json) <= @max_frame_state_json_length -> json
          _ -> "{}"
        end
    end
  end

  defp encode_state(_), do: "{}"

  defp do_encode_state(state) when is_map(state) do
    case Jason.encode(state) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  defp do_encode_state(_), do: nil

  defp normalize_action(params) when is_map(params) do
    payload = Map.get(params, "untrustedData") || Map.get(params, :untrustedData) || params
    trusted_data = Map.get(params, "trustedData") || Map.get(params, :trustedData) || %{}

    state =
      payload
      |> fetch_any(["state", :state])
      |> decode_state()

    fid = payload |> fetch_any(["fid", :fid]) |> parse_integer()

    message_bytes =
      trusted_data
      |> fetch_any(["messageBytes", :messageBytes, "message_bytes", :message_bytes])
      |> normalize_blank()

    cond do
      not (is_integer(fid) and fid > 0) ->
        {:error, :invalid_fid}

      not is_binary(message_bytes) ->
        {:error, :missing_trusted_message_bytes}

      true ->
        {:ok,
         %{
           fid: fid,
           button_index:
             payload
             |> fetch_any(["buttonIndex", :buttonIndex, "button_index"])
             |> parse_integer(),
           input_text:
             payload
             |> fetch_any(["inputText", :inputText, "input_text", :input_text])
             |> to_string_or_empty(),
           cast_hash:
             payload
             |> fetch_any(["messageHash", :messageHash, "castHash", :castHash])
             |> normalize_blank(),
           trusted_message_bytes: message_bytes,
           state: state
         }}
    end
  end

  defp normalize_action(_), do: {:error, :invalid_payload}

  defp decode_state(nil), do: %{}
  defp decode_state(state) when is_map(state), do: stringify_keys(state)

  defp decode_state(state) when is_binary(state) do
    case Jason.decode(state) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      _ -> %{}
    end
  end

  defp decode_state(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      value = if is_map(v), do: stringify_keys(v), else: v
      {key, value}
    end)
  end

  defp fetch_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp fetch_any(_, _), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      :error -> nil
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value), do: to_string(value)

  defp new_session_ref do
    LemonCore.Id.session_id()
  end

  defp maybe_verify_trusted_data(action) do
    if verify_trusted_data_enabled?() do
      case HubClient.verify_message_bytes(action.trusted_message_bytes, config()) do
        {:ok, %{fid: nil}} ->
          {:error, :trusted_data_missing_fid}

        {:ok, %{fid: verifier_fid}} when verifier_fid == action.fid ->
          :ok

        {:ok, %{fid: verifier_fid}} ->
          {:error, {:trusted_data_fid_mismatch, verifier_fid, action.fid}}

        {:error, reason} ->
          {:error, {:trusted_data_verification_failed, reason}}
      end
    else
      :ok
    end
  end

  defp verify_trusted_data_enabled? do
    case config()[:verify_trusted_data] do
      nil -> true
      value -> truthy?(value)
    end
  end

  defp with_signed_session_ref(state) when is_map(state) do
    session_ref = normalize_blank(get_in(state, ["session_ref"]))
    fid = get_in(state, ["fid"]) |> parse_integer()
    state = Map.delete(state, "session_sig")

    if is_binary(session_ref) and is_integer(fid) and fid > 0 do
      case session_signature(session_ref, fid) do
        nil -> state
        signature -> Map.put(state, "session_sig", signature)
      end
    else
      state
    end
  end

  defp with_signed_session_ref(state), do: state

  defp verified_state_session_ref(state) when is_map(state) do
    session_ref = normalize_blank(get_in(state, ["session_ref"]))
    session_sig = normalize_blank(get_in(state, ["session_sig"]))
    fid = get_in(state, ["fid"]) |> parse_integer()

    if is_binary(session_ref) and is_integer(fid) and fid > 0 and
         valid_session_signature?(session_ref, session_sig, fid) do
      session_ref
    else
      nil
    end
  end

  defp verified_state_session_ref(_), do: nil

  defp valid_session_signature?(session_ref, signature, fid)
       when is_binary(session_ref) and is_binary(signature) and is_integer(fid) and fid > 0 do
    case session_signature(session_ref, fid) do
      expected when is_binary(expected) ->
        byte_size(expected) == byte_size(signature) and
          Plug.Crypto.secure_compare(signature, expected)

      _ ->
        false
    end
  end

  defp valid_session_signature?(_, _, _), do: false

  defp session_signature(session_ref, fid)
       when is_binary(session_ref) and is_integer(fid) and fid > 0 do
    case state_secret() do
      secret when is_binary(secret) ->
        :crypto.mac(:hmac, :sha256, secret, "#{fid}:#{session_ref}")
        |> Base.url_encode64(padding: false)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp session_signature(_, _), do: nil

  defp farcaster_account_id do
    normalize_blank(config()[:account_id]) ||
      normalize_blank(System.get_env("FARCASTER_ACCOUNT_ID")) ||
      @default_account_id
  end

  defp state_secret do
    normalize_blank(config()[:state_secret]) ||
      normalize_blank(System.get_env("FARCASTER_STATE_SECRET")) ||
      normalize_blank(System.get_env("LEMON_STATE_SECRET")) ||
      fallback_state_secret()
  end

  defp fallback_state_secret do
    cookie = :erlang.get_cookie() |> to_string()
    node_name = node() |> to_string()

    :crypto.hash(:sha256, "farcaster-state:" <> cookie <> ":" <> node_name)
    |> Base.url_encode64(padding: false)
  rescue
    _ -> "farcaster-state-fallback"
  end

  defp truncate_state_prompt(nil), do: nil

  defp truncate_state_prompt(prompt) when is_binary(prompt) do
    String.slice(prompt, 0, @max_state_prompt_length)
  end

  defp truncate_state_prompt(prompt) do
    prompt
    |> to_string()
    |> truncate_state_prompt()
  end

  defp html_escape(nil), do: ""

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp config do
    LemonGateway.Transports.Farcaster.config()
  end

  defp normalize_path(path) when is_binary(path) do
    path =
      path
      |> String.trim()
      |> case do
        "" -> @default_action_path
        p -> if String.starts_with?(p, "/"), do: p, else: "/" <> p
      end

    if String.length(path) > 1, do: String.trim_trailing(path, "/"), else: path
  end

  defp normalize_path(_), do: @default_action_path

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(value) do
    value
    |> to_string()
    |> normalize_blank()
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp sanitize_session_component(value, fallback) when is_binary(fallback) do
    sanitized =
      value
      |> to_string_or_empty()
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
      |> String.trim("_")
      |> String.slice(0, @max_session_component_length)

    if sanitized == "", do: fallback, else: sanitized
  end

  defp sanitize_session_component(_value, fallback), do: fallback

  defp clip_state_values(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, clip_state_value(value)}
    end)
  end

  defp clip_state_values(value), do: value

  defp clip_state_value(value) when is_binary(value) do
    String.slice(value, 0, @max_frame_state_value_length)
  end

  defp clip_state_value(value) when is_map(value), do: clip_state_values(value)
  defp clip_state_value(value), do: value

  defp clip_frame_meta(value, max_len)
       when is_binary(value) and is_integer(max_len) and max_len > 0 do
    String.slice(value, 0, max_len)
  end

  defp clip_frame_meta(value, max_len) when is_integer(max_len) and max_len > 0 do
    value
    |> to_string_or_empty()
    |> clip_frame_meta(max_len)
  end

  defp clip_frame_meta(value, _), do: to_string_or_empty(value)

  defp build_public_url(base, path) when is_binary(base) and is_binary(path) do
    base = String.trim(base)
    path = normalize_path(path)

    case URI.parse(base) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%{uri | path: path, query: nil, fragment: nil})

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
