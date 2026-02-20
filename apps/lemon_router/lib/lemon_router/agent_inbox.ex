defmodule LemonRouter.AgentInbox do
  @moduledoc """
  BEAM-local inbox API for sending messages to agent sessions.

  Session selectors:

  - `:latest` - latest active/recent session
  - `:new` - route-preserving new fork (`:sub:<id>`)
  - explicit session key - direct target
  """

  alias LemonCore.{RunRequest, SessionKey}
  alias LemonRouter.{AgentDirectory, AgentEndpoints}

  @typedoc "Session selector for inbox delivery."
  @type session_selector :: :latest | :new | binary()

  @typedoc "Primary inbox routing target."
  @type target_resolution :: %{
          route: AgentEndpoints.route(),
          endpoint: AgentEndpoints.endpoint() | nil,
          target: binary()
        }

  @typedoc "Resolved session destination."
  @type resolution :: %{
          session_key: binary(),
          route_session_key: binary() | nil,
          selector: session_selector(),
          resolved_from: :explicit | :latest | :new | :fallback_main,
          route: AgentEndpoints.route() | nil,
          target: binary() | nil
        }

  @doc """
  Send a prompt to an agent inbox.

  Options:

  - `:session` - `:latest | :new | session_key` (default: `:latest`)
  - `:to` / `:endpoint` / `:route` - primary destination
  - `:deliver_to` - optional fanout destinations (endpoint aliases, shorthand, or route maps)
  - `:queue_mode`, `:engine_id`, `:cwd`, `:tool_policy`, `:meta`, `:source`
  """
  @spec send(binary(), binary(), keyword()) ::
          {:ok,
           %{
             run_id: binary(),
             session_key: binary(),
             selector: session_selector(),
             fanout_count: non_neg_integer()
           }}
          | {:error, term()}
  def send(agent_id, prompt, opts \\ [])

  def send(agent_id, prompt, opts)
      when is_binary(agent_id) and is_binary(prompt) and is_list(opts) do
    with :ok <- validate_prompt(prompt),
         {:ok, selector} <- normalize_session_selector(opts[:session]),
         {:ok, primary_target} <- resolve_primary_target(agent_id, opts),
         {:ok, fanout} <- resolve_fanout_targets(agent_id, primary_target, opts),
         opts =
           opts
           |> Keyword.put(:primary_target, primary_target)
           |> Keyword.put(:fanout_targets, fanout),
         {:ok, resolved} <- resolve_session(agent_id, selector, opts),
         {:ok, run_id} <- submit(agent_id, prompt, resolved, opts) do
      {:ok,
       %{
         run_id: run_id,
         session_key: resolved.session_key,
         selector: resolved.selector,
         fanout_count: length(fanout.routes)
       }}
    end
  end

  def send(_agent_id, _prompt, _opts), do: {:error, :invalid_arguments}

  @doc """
  Resolve a selector (`:latest`, `:new`, explicit key) into a concrete session key.
  """
  @spec resolve_session(binary(), session_selector(), keyword()) ::
          {:ok, resolution()} | {:error, term()}
  def resolve_session(agent_id, selector, opts \\ [])

  def resolve_session(agent_id, selector, opts) when is_binary(selector) do
    with :ok <- validate_session_key(selector),
         :ok <- ensure_session_agent(agent_id, selector) do
      route = route_from_session_key(selector)
      target = opts[:primary_target] && opts[:primary_target].target

      {:ok,
       %{
         session_key: selector,
         route_session_key: route && AgentEndpoints.route_session_key(agent_id, route),
         selector: selector,
         resolved_from: :explicit,
         route: route,
         target: target
       }}
    end
  end

  def resolve_session(agent_id, :latest, opts) when is_binary(agent_id) and agent_id != "" do
    route_filter = route_filter_from_opts(opts)
    primary_route = primary_route_from_opts(opts)
    primary_target = opts[:primary_target] && opts[:primary_target].target

    case AgentDirectory.latest_session(agent_id, route: route_filter) do
      {:ok, session} ->
        route = route_from_session_key(session.session_key) || primary_route

        {:ok,
         %{
           session_key: session.session_key,
           route_session_key: route && AgentEndpoints.route_session_key(agent_id, route),
           selector: :latest,
           resolved_from: :latest,
           route: route,
           target: primary_target
         }}

      {:error, :not_found} ->
        cond do
          is_map(primary_route) ->
            session_key = AgentEndpoints.route_session_key(agent_id, primary_route)

            {:ok,
             %{
               session_key: session_key,
               route_session_key: session_key,
               selector: :latest,
               resolved_from: :latest,
               route: primary_route,
               target: primary_target
             }}

          true ->
            main = SessionKey.main(agent_id)

            {:ok,
             %{
               session_key: main,
               route_session_key: nil,
               selector: :latest,
               resolved_from: :fallback_main,
               route: nil,
               target: primary_target
             }}
        end
    end
  end

  def resolve_session(agent_id, :new, opts) when is_binary(agent_id) and agent_id != "" do
    primary_route = primary_route_from_opts(opts)
    primary_target = opts[:primary_target] && opts[:primary_target].target

    base_session =
      cond do
        is_binary(opts[:base_session_key]) and SessionKey.valid?(opts[:base_session_key]) ->
          opts[:base_session_key]

        is_map(primary_route) ->
          AgentEndpoints.route_session_key(agent_id, primary_route)

        true ->
          latest_base_session_for_new(agent_id, opts)
      end

    case SessionKey.parse(base_session) do
      %{
        kind: :channel_peer,
        agent_id: parsed_agent_id,
        channel_id: channel_id,
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: thread_id
      } ->
        route = %{
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: peer_kind,
          peer_id: peer_id,
          thread_id: thread_id
        }

        route_session_key = AgentEndpoints.route_session_key(parsed_agent_id || agent_id, route)
        session_key = with_sub_id(route_session_key, new_sub_id())

        {:ok,
         %{
           session_key: session_key,
           route_session_key: route_session_key,
           selector: :new,
           resolved_from: :new,
           route: route,
           target: primary_target
         }}

      _ ->
        main = SessionKey.main(agent_id)

        {:ok,
         %{
           session_key: main,
           route_session_key: nil,
           selector: :new,
           resolved_from: :fallback_main,
           route: nil,
           target: primary_target
         }}
    end
  rescue
    _ ->
      main = SessionKey.main(agent_id)

      {:ok,
       %{
         session_key: main,
         route_session_key: nil,
         selector: :new,
         resolved_from: :fallback_main,
         route: nil,
         target: nil
       }}
  end

  def resolve_session(_agent_id, selector, _opts),
    do: {:error, {:invalid_session_selector, selector}}

  defp latest_base_session_for_new(agent_id, opts) do
    route_filter = route_filter_from_opts(opts)

    case AgentDirectory.latest_route_session(agent_id, route: route_filter) do
      {:ok, session} ->
        route_from_session_key(session.session_key)
        |> case do
          route when is_map(route) -> AgentEndpoints.route_session_key(agent_id, route)
          _ -> session.session_key
        end

      {:error, :not_found} ->
        case AgentDirectory.latest_session(agent_id, route: route_filter) do
          {:ok, session} -> session.session_key
          {:error, :not_found} -> SessionKey.main(agent_id)
        end
    end
  end

  defp resolve_primary_target(agent_id, opts) do
    target =
      opts[:to] ||
        opts[:endpoint] ||
        opts[:target] ||
        opts[:route]

    if is_nil(target) do
      {:ok, nil}
    else
      AgentEndpoints.resolve(
        agent_id,
        target,
        account_id: opts[:account_id],
        peer_kind: opts[:peer_kind]
      )
    end
  end

  defp resolve_fanout_targets(agent_id, primary_target, opts) do
    primary_signature =
      case primary_target do
        %{route: route} when is_map(route) -> AgentEndpoints.route_signature(route)
        _ -> nil
      end

    items = normalize_fanout_items(opts[:deliver_to] || opts[:fanout] || opts[:fanout_to])

    Enum.reduce_while(items, {:ok, %{routes: [], targets: [], signatures: MapSet.new()}}, fn item,
                                                                                             {:ok,
                                                                                              acc} ->
      case AgentEndpoints.resolve(agent_id, item,
             account_id: opts[:account_id],
             peer_kind: opts[:peer_kind]
           ) do
        {:ok, resolved} ->
          signature = AgentEndpoints.route_signature(resolved.route)

          cond do
            signature == primary_signature ->
              {:cont, {:ok, acc}}

            MapSet.member?(acc.signatures, signature) ->
              {:cont, {:ok, acc}}

            true ->
              updated = %{
                routes: acc.routes ++ [resolved.route],
                targets: acc.targets ++ [resolved.target],
                signatures: MapSet.put(acc.signatures, signature)
              }

              {:cont, {:ok, updated}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_fanout_target, item, reason}}}
      end
    end)
    |> case do
      {:ok, %{routes: routes, targets: targets}} ->
        {:ok, %{routes: routes, targets: targets}}

      error ->
        error
    end
  end

  defp normalize_fanout_items(nil), do: []
  defp normalize_fanout_items(items) when is_list(items), do: Enum.reject(items, &is_nil/1)
  defp normalize_fanout_items(item), do: [item]

  defp route_filter_from_opts(opts) do
    cond do
      is_map(opts[:primary_target] && opts[:primary_target].route) ->
        AgentEndpoints.route_filter(opts[:primary_target].route)

      is_map(opts[:route]) ->
        opts[:route]

      true ->
        %{}
    end
  end

  defp primary_route_from_opts(opts) do
    cond do
      is_map(opts[:primary_target] && opts[:primary_target].route) ->
        opts[:primary_target].route

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp submit(agent_id, prompt, resolved, opts) do
    session_key = resolved.session_key
    parsed = parse_session(session_key)
    origin = request_origin(parsed, resolved.route)
    meta = build_meta(resolved, parsed, opts)

    request =
      RunRequest.new(%{
        origin: origin,
        session_key: session_key,
        agent_id: agent_id,
        prompt: prompt,
        queue_mode: normalize_queue_mode(opts[:queue_mode]),
        engine_id: opts[:engine_id],
        cwd: opts[:cwd],
        tool_policy: opts[:tool_policy],
        meta: meta
      })

    case submitter() do
      mod when is_atom(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :submit, 1) do
          mod.submit(request)
        else
          {:error, {:invalid_submitter, mod}}
        end

      fun when is_function(fun, 1) ->
        fun.(request)

      other ->
        {:error, {:invalid_submitter, other}}
    end
  rescue
    e -> {:error, e}
  end

  defp submitter do
    Application.get_env(:lemon_router, :agent_inbox_submitter, LemonRouter)
  end

  defp request_origin(%{kind: :channel_peer}, _route), do: :channel
  defp request_origin(_parsed, route) when is_map(route), do: :channel
  defp request_origin(_parsed, _route), do: :control_plane

  defp build_meta(resolved, parsed_session, opts) do
    base_meta = normalize_meta(opts[:meta])
    inbox_meta = normalize_meta(map_get(base_meta, :agent_inbox))
    fanout = opts[:fanout_targets] || %{routes: [], targets: []}
    route = route_from_parsed(parsed_session) || resolved.route

    channel_meta =
      case route do
        %{channel_id: channel_id, account_id: account_id, peer_kind: peer_kind, peer_id: peer_id} =
            route_map ->
          maybe_telegram_ids =
            if channel_id == "telegram" do
              %{
                chat_id: parse_int(peer_id),
                topic_id: parse_int(route_map.thread_id)
              }
            else
              %{}
            end

          Map.merge(
            %{
              channel_id: channel_id,
              account_id: account_id,
              peer: %{
                kind: peer_kind,
                id: peer_id,
                thread_id: route_map.thread_id
              },
              channel_context: %{
                channel_id: channel_id,
                account_id: account_id,
                peer_kind: peer_kind,
                peer_id: peer_id,
                thread_id: route_map.thread_id
              }
            },
            maybe_telegram_ids
          )

        _ ->
          %{}
      end

    merged_meta =
      base_meta
      |> Map.merge(channel_meta)
      |> maybe_put(:fanout_routes, fanout.routes)
      |> Map.put(:agent_inbox_message, true)
      |> maybe_put(:agent_inbox_followup, normalize_queue_mode(opts[:queue_mode]) == :followup)
      |> Map.put(
        :agent_inbox,
        Map.merge(
          inbox_meta,
          %{
            source: normalize_source(opts[:source]),
            selector: selector_label(resolved.selector),
            resolved_from: resolved.resolved_from,
            resolved_session_key: resolved.session_key,
            route_session_key: resolved.route_session_key,
            target: resolved.target,
            queue_mode: normalize_queue_mode(opts[:queue_mode]),
            fanout_targets: fanout.targets,
            requested_at_ms: System.system_time(:millisecond)
          }
        )
      )

    merged_meta
  end

  defp route_from_parsed(%{
         kind: :channel_peer,
         channel_id: channel_id,
         account_id: account_id,
         peer_kind: peer_kind,
         peer_id: peer_id,
         thread_id: thread_id
       }) do
    %{
      channel_id: channel_id,
      account_id: account_id,
      peer_kind: peer_kind,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end

  defp route_from_parsed(_), do: nil

  defp route_from_session_key(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      parsed when is_map(parsed) -> route_from_parsed(parsed)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp route_from_session_key(_), do: nil

  defp parse_session(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      {:error, _} -> nil
      parsed -> parsed
    end
  rescue
    _ -> nil
  end

  defp parse_session(_), do: nil

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error, :empty_prompt}
    else
      :ok
    end
  end

  defp validate_prompt(_), do: {:error, :invalid_prompt}

  defp normalize_session_selector(nil), do: {:ok, :latest}
  defp normalize_session_selector(:latest), do: {:ok, :latest}
  defp normalize_session_selector(:new), do: {:ok, :new}

  defp normalize_session_selector(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "latest" -> {:ok, :latest}
      "new" -> {:ok, :new}
      other when other != "" -> {:ok, value}
      _ -> {:error, :invalid_session_selector}
    end
  end

  defp normalize_session_selector(other), do: {:error, {:invalid_session_selector, other}}

  defp validate_session_key(session_key) when is_binary(session_key) do
    if SessionKey.valid?(session_key),
      do: :ok,
      else: {:error, {:invalid_session_key, session_key}}
  end

  defp validate_session_key(_), do: {:error, :invalid_session_key}

  defp ensure_session_agent(agent_id, session_key)
       when is_binary(agent_id) and is_binary(session_key) do
    case SessionKey.agent_id(session_key) do
      nil ->
        {:error, {:invalid_session_key, session_key}}

      ^agent_id ->
        :ok

      other ->
        {:error, {:session_agent_mismatch, %{expected: agent_id, actual: other}}}
    end
  end

  defp ensure_session_agent(_agent_id, _session_key), do: {:error, :invalid_session_key}

  defp with_sub_id(session_key, sub_id)
       when is_binary(session_key) and is_binary(sub_id) and session_key != "" and sub_id != "" do
    if String.contains?(session_key, ":sub:") do
      session_key
    else
      session_key <> ":sub:" <> sub_id
    end
  end

  defp with_sub_id(session_key, _sub_id), do: session_key

  defp new_sub_id do
    LemonCore.Id.session_id()
    |> String.replace_prefix("sess_", "inbox_")
  rescue
    _ -> "inbox_#{System.unique_integer([:positive])}"
  end

  defp normalize_source(nil), do: "beam"
  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(other), do: inspect(other)

  defp normalize_queue_mode(nil), do: :followup
  defp normalize_queue_mode(:collect), do: :collect
  defp normalize_queue_mode(:followup), do: :followup
  defp normalize_queue_mode(:steer), do: :steer
  defp normalize_queue_mode(:steer_backlog), do: :steer_backlog
  defp normalize_queue_mode(:interrupt), do: :interrupt

  defp normalize_queue_mode(mode) when is_binary(mode) do
    case String.downcase(String.trim(mode)) do
      "collect" -> :collect
      "followup" -> :followup
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      "interrupt" -> :interrupt
      _ -> :followup
    end
  end

  defp normalize_queue_mode(_), do: :followup

  defp selector_label(:latest), do: "latest"
  defp selector_label(:new), do: "new"
  defp selector_label(selector) when is_binary(selector), do: "explicit"
  defp selector_label(_), do: "unknown"

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp maybe_put(map, _key, value) when value in [nil, []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
