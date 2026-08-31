defmodule LemonBrowser.ControllerBroker do
  @moduledoc """
  Authenticated, fail-closed broker for browser controllers.

  A trusted control-plane caller mints a short-lived, single-use ticket whose
  server-owned identity is bound to controller, browser profile, session, run,
  and an allowlisted capability set. The controller consumes that ticket from
  its WebSocket process. Commands are then delivered only to an exact matching
  live controller and results are accepted only from that registered process.
  """

  use GenServer

  alias LemonCore.Id

  @name __MODULE__
  @default_ticket_ttl_ms 30_000
  @max_ticket_ttl_ms 300_000
  @default_timeout_ms 30_000
  @default_heartbeat_ttl_ms 60_000
  @capabilities ~w(tabs navigate inspect interact evaluate cookies files state)

  @type binding :: %{
          optional(:controller_id) => String.t(),
          optional(:browser_profile_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:run_id) => String.t()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec issue_ticket(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_ticket(attrs, opts \\ []) when is_map(attrs) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:issue_ticket, attrs, opts})
  end

  @spec register(String.t(), pid(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register(ticket, controller_pid, metadata \\ %{}, opts \\ [])
      when is_binary(ticket) and is_pid(controller_pid) and is_map(metadata) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:register, ticket, controller_pid, metadata})
  end

  @spec heartbeat(String.t(), pid(), keyword()) :: :ok | {:error, term()}
  def heartbeat(controller_id, controller_pid, opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:heartbeat, controller_id, controller_pid})
  end

  @spec request(binding(), String.t(), map(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(binding, method, args, timeout_ms \\ @default_timeout_ms, opts \\ [])
      when is_map(binding) and is_binary(method) and is_map(args) and is_integer(timeout_ms) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:request, binding, method, args, timeout_ms}, timeout_ms + 1_000)
  end

  @spec complete(String.t(), pid(), String.t(), {:ok, term()} | {:error, term()}, keyword()) ::
          :ok | {:error, term()}
  def complete(controller_id, controller_pid, request_id, result, opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:complete, controller_id, controller_pid, request_id, result})
  end

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :status)
  end

  @spec allowed_capabilities() :: [String.t()]
  def allowed_capabilities, do: @capabilities

  @spec required_capability(String.t()) :: String.t() | nil
  def required_capability(method) do
    case normalize_method(method) do
      method when method in ["browser.tabs", "browser.tabActivate", "browser.tabClose"] ->
        "tabs"

      method when method in ["browser.navigate", "browser.back", "browser.tabOpen"] ->
        "navigate"

      method
      when method in [
             "browser.snapshot",
             "browser.getContent",
             "browser.screenshot",
             "browser.events"
           ] ->
        "inspect"

      method
      when method in [
             "browser.click",
             "browser.type",
             "browser.hover",
             "browser.selectOption",
             "browser.press",
             "browser.scroll",
             "browser.waitForSelector"
           ] ->
        "interact"

      "browser.evaluate" ->
        "evaluate"

      method when method in ["browser.getCookies", "browser.setCookies"] ->
        "cookies"

      method when method in ["browser.setInputFiles", "browser.download"] ->
        "files"

      "browser.clearState" ->
        "state"

      _ ->
        nil
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       tickets: %{},
       controllers: %{},
       monitors: %{},
       pending: %{},
       ticket_ttl_ms: Keyword.get(opts, :ticket_ttl_ms, @default_ticket_ttl_ms),
       heartbeat_ttl_ms: Keyword.get(opts, :heartbeat_ttl_ms, @default_heartbeat_ttl_ms)
     }}
  end

  @impl true
  def handle_call({:issue_ticket, attrs, opts}, _from, state) do
    with {:ok, identity} <- normalize_identity(attrs),
         {:ok, ttl_ms} <- normalize_ttl(Keyword.get(opts, :ttl_ms, state.ticket_ttl_ms)) do
      ticket = random_ticket()
      ticket_hash = hash_ticket(ticket)
      expires_at_ms = now_ms() + ttl_ms

      tickets =
        state.tickets
        |> prune_tickets()
        |> Map.put(ticket_hash, Map.put(identity, :expires_at_ms, expires_at_ms))

      {:reply,
       {:ok,
        %{
          ticket: ticket,
          expires_at_ms: expires_at_ms,
          controller_id: identity.controller_id,
          capabilities: identity.capabilities
        }}, %{state | tickets: tickets}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:register, ticket, controller_pid, metadata}, _from, state) do
    ticket_hash = hash_ticket(ticket)
    {ticket_data, tickets} = Map.pop(state.tickets, ticket_hash)
    state = %{state | tickets: tickets}

    cond do
      is_nil(ticket_data) ->
        {:reply, {:error, :invalid_or_consumed_ticket}, state}

      ticket_data.expires_at_ms <= now_ms() ->
        {:reply, {:error, :expired_ticket}, state}

      true ->
        state = remove_controller(state, ticket_data.controller_id, :replaced)
        monitor_ref = Process.monitor(controller_pid)

        controller =
          ticket_data
          |> Map.drop([:expires_at_ms])
          |> Map.merge(%{
            pid: controller_pid,
            monitor_ref: monitor_ref,
            metadata: sanitize_metadata(metadata),
            connected_at_ms: now_ms(),
            last_heartbeat_at_ms: now_ms()
          })

        controllers = Map.put(state.controllers, controller.controller_id, controller)
        monitors = Map.put(state.monitors, monitor_ref, controller.controller_id)

        {:reply, {:ok, public_controller(controller)},
         %{state | controllers: controllers, monitors: monitors}}
    end
  end

  def handle_call({:heartbeat, controller_id, controller_pid}, _from, state) do
    case Map.get(state.controllers, controller_id) do
      %{pid: ^controller_pid} = controller ->
        controllers =
          Map.put(state.controllers, controller_id, %{
            controller
            | last_heartbeat_at_ms: now_ms()
          })

        {:reply, :ok, %{state | controllers: controllers}}

      _ ->
        {:reply, {:error, :controller_identity_mismatch}, state}
    end
  end

  def handle_call({:request, binding, method, args, timeout_ms}, from, state) do
    state = prune_stale_controllers(state)

    with {:ok, controller} <- find_controller(state.controllers, binding),
         {:ok, capability} <- authorize_method(controller, method),
         {:ok, timeout_ms} <- normalize_timeout(timeout_ms) do
      request_id = Id.uuid()
      timer_ref = Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)

      pending =
        Map.put(state.pending, request_id, %{
          from: from,
          timer_ref: timer_ref,
          controller_id: controller.controller_id,
          controller_pid: controller.pid
        })

      send(controller.pid, {
        :browser_controller_command,
        %{
          "requestId" => request_id,
          "method" => normalize_method(method),
          "args" => args,
          "timeoutMs" => timeout_ms,
          "capability" => capability,
          "controllerId" => controller.controller_id,
          "browserProfileId" => controller.browser_profile_id,
          "sessionId" => controller.session_id,
          "runId" => controller.run_id
        }
      })

      {:noreply, %{state | pending: pending}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:complete, controller_id, controller_pid, request_id, result},
        _from,
        state
      ) do
    case Map.get(state.pending, request_id) do
      %{controller_id: ^controller_id, controller_pid: ^controller_pid} = pending ->
        _ = Process.cancel_timer(pending.timer_ref)
        GenServer.reply(pending.from, normalize_result(result))
        {:reply, :ok, %{state | pending: Map.delete(state.pending, request_id)}}

      nil ->
        {:reply, {:error, :unknown_request}, state}

      _ ->
        {:reply, {:error, :controller_identity_mismatch}, state}
    end
  end

  def handle_call(:status, _from, state) do
    state = prune_stale_controllers(state)
    tickets = prune_tickets(state.tickets)

    payload = %{
      controllers: state.controllers |> Map.values() |> Enum.map(&public_controller/1),
      controller_count: map_size(state.controllers),
      pending_request_count: map_size(state.pending),
      unconsumed_ticket_count: map_size(tickets),
      allowed_capabilities: @capabilities
    }

    {:reply, payload, %{state | tickets: tickets}}
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {request, pending} ->
        send(request.controller_pid, {
          :browser_controller_cancel,
          %{"requestId" => request_id, "reason" => "timeout"}
        })

        GenServer.reply(request.from, {:error, :browser_controller_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {controller_id, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, remove_controller(state, controller_id, :controller_disconnected)}
    end
  end

  defp normalize_identity(attrs) do
    with {:ok, controller_id} <- required_string(attrs, :controller_id),
         {:ok, browser_profile_id} <- required_string(attrs, :browser_profile_id),
         {:ok, session_id} <- required_string(attrs, :session_id),
         {:ok, principal_id} <- required_string(attrs, :principal_id) do
      {:ok,
       %{
         controller_id: controller_id,
         browser_profile_id: browser_profile_id,
         session_id: session_id,
         run_id: optional_string(attrs, :run_id),
         principal_id: principal_id,
         capabilities: filter_capabilities(value(attrs, :capabilities))
       }}
    end
  end

  defp find_controller(controllers, binding) do
    requested_id = optional_string(binding, :controller_id)

    matches =
      controllers
      |> Map.values()
      |> Enum.filter(fn controller ->
        (is_nil(requested_id) or controller.controller_id == requested_id) and
          binding_matches?(controller, binding, :browser_profile_id) and
          binding_matches?(controller, binding, :session_id) and
          binding_matches?(controller, binding, :run_id)
      end)

    case matches do
      [controller] -> {:ok, controller}
      [] -> {:error, :browser_controller_not_found}
      _ -> {:error, :ambiguous_browser_controller}
    end
  end

  defp binding_matches?(controller, binding, key) do
    case optional_string(binding, key) do
      nil -> true
      expected -> Map.get(controller, key) == expected
    end
  end

  defp authorize_method(controller, method) do
    case required_capability(method) do
      nil ->
        {:error, :unsupported_browser_method}

      capability ->
        if capability in controller.capabilities,
          do: {:ok, capability},
          else: {:error, {:browser_capability_denied, capability}}
    end
  end

  defp remove_controller(state, controller_id, reason) do
    case Map.pop(state.controllers, controller_id) do
      {nil, controllers} ->
        %{state | controllers: controllers}

      {controller, controllers} ->
        if reason != :controller_disconnected do
          Process.demonitor(controller.monitor_ref, [:flush])
        end

        {failed, retained} =
          Enum.split_with(state.pending, fn {_id, request} ->
            request.controller_id == controller_id
          end)

        Enum.each(failed, fn {request_id, request} ->
          _ = Process.cancel_timer(request.timer_ref)

          send(request.controller_pid, {
            :browser_controller_cancel,
            %{"requestId" => request_id, "reason" => to_string(reason)}
          })

          GenServer.reply(request.from, {:error, reason})
        end)

        %{
          state
          | controllers: controllers,
            monitors: Map.delete(state.monitors, controller.monitor_ref),
            pending: Map.new(retained)
        }
    end
  end

  defp public_controller(controller) do
    %{
      controller_id: controller.controller_id,
      browser_profile_id: controller.browser_profile_id,
      session_id: controller.session_id,
      run_id: controller.run_id,
      principal_id: controller.principal_id,
      capabilities: controller.capabilities,
      metadata: controller.metadata,
      connected_at_ms: controller.connected_at_ms,
      last_heartbeat_at_ms: controller.last_heartbeat_at_ms
    }
  end

  defp sanitize_metadata(metadata) do
    metadata
    |> Map.take(["name", "version", "browser", :name, :version, :browser])
    |> Map.new(fn {key, value} -> {to_string(key), safe_metadata_value(value)} end)
  end

  defp safe_metadata_value(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp safe_metadata_value(value) when is_number(value) or is_boolean(value), do: value
  defp safe_metadata_value(_value), do: nil

  defp filter_capabilities(capabilities) do
    capabilities
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @capabilities))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, _reason} = result), do: result
  defp normalize_result(value), do: {:ok, value}

  defp normalize_ttl(value) when is_integer(value) and value > 0,
    do: {:ok, min(value, @max_ticket_ttl_ms)}

  defp normalize_ttl(_value), do: {:error, :invalid_ticket_ttl}

  defp normalize_timeout(value) when is_integer(value) and value > 0,
    do: {:ok, min(value, 120_000)}

  defp normalize_timeout(_value), do: {:error, :invalid_timeout}

  defp prune_tickets(tickets) do
    now = now_ms()
    Map.reject(tickets, fn {_hash, ticket} -> ticket.expires_at_ms <= now end)
  end

  defp prune_stale_controllers(state) do
    stale_ids =
      state.controllers
      |> Map.values()
      |> Enum.filter(fn controller ->
        not Process.alive?(controller.pid) or
          now_ms() - controller.last_heartbeat_at_ms > state.heartbeat_ttl_ms
      end)
      |> Enum.map(& &1.controller_id)

    Enum.reduce(stale_ids, state, fn controller_id, acc ->
      remove_controller(acc, controller_id, :controller_heartbeat_expired)
    end)
  end

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, {:missing_browser_controller_identity, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp normalize_method("browser." <> _rest = method), do: method
  defp normalize_method(method), do: "browser.#{method}"
  defp random_ticket, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash_ticket(ticket), do: :crypto.hash(:sha256, ticket)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
