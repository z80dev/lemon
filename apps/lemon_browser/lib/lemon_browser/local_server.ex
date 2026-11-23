defmodule LemonBrowser.LocalServer do
  @moduledoc """
  Local browser driver backed by a Node + Playwright helper process.

  This is meant to provide "local browser mode" without requiring a paired node
  connection over the control plane.

  The helper is `local-driver.js` from `clients/lemon-browser-node` and speaks a
  line-delimited JSON protocol over stdin/stdout:

    request:  {"id": "...", "method": "browser.navigate", "args": {...}, "timeoutMs": 30000,
               "deadlineAtMs": 1790000000000}
    response: {"id": "...", "ok": true, "result": {...}}
    error:    {"id": "...", "ok": false, "error": "...", "code": "not_started" | "timeout" | "outcome_unknown"}

  The driver runs one request at a time and never starts one after its
  deadline (`deadlineAtMs`, or `timeoutMs` after the driver read it, whichever
  is earlier). A side-effecting request that did not finish, or whose driver
  exited or stopped answering, replies `{:error, :outcome_unknown}`: it may
  have taken effect and is never retried. Read-only requests reply
  `"Browser request timed out"` instead.

  The driver resolves from `LEMON_BROWSER_DRIVER_PATH`, then the copy runtime
  releases bundle under this app's `priv/driver`, then a source checkout's
  `clients/lemon-browser-node/dist` under `LemonCore.Runtime.Env.lemon_root/0`.
  """

  use GenServer

  require Logger

  alias LemonCore.Env
  alias LemonCore.Id
  alias LemonCore.ProcessGroup

  @name __MODULE__
  # The driver answers by the request deadline; this backstop only covers a
  # driver that stopped answering.
  @reply_grace_ms 2_000
  @read_only_methods ~w(browser.tabs browser.screenshot browser.waitForSelector
                        browser.getContent browser.snapshot browser.getCookies browser.cdp)

  @type result :: {:ok, term()} | {:error, String.t() | :outcome_unknown}
  @type server :: GenServer.server()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec stop(server()) :: :ok
  def stop(server \\ @name) do
    GenServer.stop(server, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  @spec request(String.t(), map(), pos_integer()) :: result()
  def request(method, args \\ %{}, timeout_ms \\ 30_000)
      when is_binary(method) and is_map(args) do
    request(@name, method, args, timeout_ms)
  end

  @spec request(server(), String.t(), map(), pos_integer()) :: result()
  def request(server, method, args, timeout_ms)
      when is_binary(method) and is_map(args) do
    call(server, {:request, method, args, timeout_ms}, method, args, timeout_ms)
  end

  @doc false
  def request(server, method, args, timeout_ms, opts) do
    call(server, {:request, method, args, timeout_ms, opts}, method, args, timeout_ms)
  end

  # The server answers every request by its own backstop, which fires before
  # this call timeout. An exit after the call was delivered cannot prove the
  # request never ran.
  defp call(server, message, method, args, timeout_ms) do
    GenServer.call(server, message, timeout_ms + @reply_grace_ms + 3_000)
  catch
    :exit, {:noproc, _} -> {:error, "Local browser server is not running"}
    :exit, _ -> unanswered(method, args, "Browser request timed out")
  end

  @doc """
  Whether a browser method only reads state. Every other method is treated as
  side-effecting: an unanswered one replies `{:error, :outcome_unknown}`.
  Mirrors `isReadOnlyBrowserMethod` in the driver.
  """
  @spec read_only_method?(String.t(), map()) :: boolean()
  def read_only_method?("browser.events", args), do: args["clear"] != true
  def read_only_method?(method, _args), do: method in @read_only_methods

  defp unanswered(method, args, read_only_error) do
    if read_only_method?(method, args),
      do: {:error, read_only_error},
      else: {:error, :outcome_unknown}
  end

  @spec status() :: map()
  def status, do: status(@name)

  @spec status(server()) :: map()
  def status(server) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, reason ->
      %{
        available: false,
        running: false,
        error: inspect(reason),
        pending_requests: 0
      }
  end

  @doc false
  def configuration(opts \\ []) do
    with {:ok, _node} <- find_node(),
         {:ok, driver} <- find_driver(opts) do
      summary = driver_config_summary(opts)

      {:ok,
       %{
         "driverPath" => driver,
         "endpoint" => configured_endpoint(opts),
         "port" => summary[:cdp_port] || 18_800,
         "launchesBrowser" => summary[:launches_browser],
         "attachOnly" => summary[:attach_only]
       }}
    else
      _ -> {:error, :not_installed}
    end
  end

  # The CDP endpoint can carry bearer credentials (relay `?token=`, hosted
  # provider URLs), and requests carry page text, so crash reports and
  # `:sys.get_status/1` never see process state or messages.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  # Process state never holds a CDP endpoint. Endpoints that come from
  # configuration (env, relay token, explicit `cdp` provider) are resolved
  # when the driver spawns. An endpoint passed as `:cdp_endpoint` (a hosted
  # provider session) has no other source, so the driver spawns during init
  # and the server stops when that driver exits.
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    base =
      Keyword.take(opts, [
        :attach_only,
        :allow_unenforced_egress,
        :driver_path,
        :user_data_dir,
        :profile_directory
      ])

    state = %{
      port: nil,
      buffer: "",
      pending: %{},
      request_count: 0,
      completed_count: 0,
      failed_count: 0,
      started_at: nil,
      last_request_at: nil,
      last_error: nil,
      last_error_at: nil,
      driver_config: nil,
      driver_opts: base
    }

    case Keyword.get(opts, :cdp_endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        state = put_endpoint_source(state, :explicit)

        case spawn_port(state, Keyword.put(base, :cdp_endpoint, endpoint)) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end

      "" ->
        {:ok, put_endpoint_source(state, :local)}

      _ ->
        {:ok, put_endpoint_source(state, :env)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call({:request, method, args, timeout_ms, opts}, from, state) do
    state =
      case Keyword.get(opts, :browser_provider) do
        provider when provider in ["local", "relay", "cdp"] ->
          put_endpoint_source(state, {:provider, provider})

        _ ->
          state
      end

    handle_call({:request, method, args, timeout_ms}, from, state)
  end

  def handle_call({:request, method, args, timeout_ms}, from, state) do
    case ensure_port(state) do
      {:ok, state} ->
        id = Id.uuid()

        payload = %{
          "id" => id,
          "method" => method,
          "args" => args,
          "timeoutMs" => timeout_ms,
          # Same host clock: the driver never starts the request after this.
          "deadlineAtMs" => System.os_time(:millisecond) + timeout_ms
        }

        line = Jason.encode!(payload) <> "\n"

        timer_ref =
          Process.send_after(self(), {:request_timeout, id}, timeout_ms + @reply_grace_ms)

        entry = %{from: from, timer: timer_ref, read_only: read_only_method?(method, args)}
        pending = Map.put(state.pending, id, entry)

        true = Port.command(state.port, line)

        {:noreply,
         %{
           state
           | pending: pending,
             request_count: state.request_count + 1,
             last_request_at: now_iso8601()
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, remember_error(state, reason)}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    state = %{state | buffer: state.buffer <> data}
    {lines, buffer} = split_lines(state.buffer)
    state = %{state | buffer: buffer}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        handle_line(line, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Local browser driver exited (status=#{status})")
    state = fail_all_pending(state, "Local browser driver exited")
    state = %{state | port: nil, buffer: ""}

    # A hosted session endpoint was not retained, so this driver cannot be
    # respawned; the owner observes the exit and releases the session.
    if resolve_driver_opts(state.driver_opts) == :explicit,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {entry, pending} ->
        reply = unanswered_reply(entry, "Browser request timed out")
        GenServer.reply(entry.from, reply)

        {:noreply,
         state
         |> Map.merge(%{pending: pending, failed_count: state.failed_count + 1})
         |> remember_error(elem(reply, 1))}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      port
      |> port_info_value(:os_pid)
      |> signal_os_process()

      Port.close(port)
    end
  end

  defp signal_os_process(pid) when is_integer(pid) do
    _ = ProcessGroup.terminate(pid)

    :ok
  catch
    _, _ -> :ok
  end

  defp signal_os_process(_pid), do: :ok

  defp ensure_port(%{port: port} = state) when is_port(port) do
    case resolve_driver_opts(state.driver_opts) do
      :explicit ->
        {:ok, state}

      opts ->
        if state.driver_config == driver_config_summary(opts) do
          {:ok, state}
        else
          {:error,
           "Browser identity changed; stop the local browser before changing its profile or CDP configuration"}
        end
    end
  end

  defp ensure_port(state) do
    case resolve_driver_opts(state.driver_opts) do
      :explicit -> {:error, "Hosted browser driver exited"}
      opts -> spawn_port(state, opts)
    end
  end

  # `opts` carry the resolved endpoint only for the duration of the spawn.
  defp spawn_port(state, opts) do
    with {:ok, node_path} <- find_node(),
         {:ok, driver_path} <- find_driver(opts) do
      args = [driver_path | driver_args(opts)]
      # Browser children and attached sessions can outlive the driver's group.
      LemonCore.NativeProcess.unsupported!()

      port =
        LemonCore.NativeProcess.open({:spawn_executable, node_path}, [
          :binary,
          :exit_status,
          :hide,
          {:args, args},
          {:env, driver_env(opts)}
        ])

      {:ok,
       %{
         state
         | port: port,
           started_at: now_iso8601(),
           last_error: nil,
           last_error_at: nil,
           driver_config: driver_config_summary(opts)
       }}
    end
  end

  defp put_endpoint_source(state, source),
    do: %{state | driver_opts: Keyword.put(state.driver_opts, :endpoint_source, source)}

  defp resolve_driver_opts(driver_opts) do
    {source, opts} = Keyword.pop(driver_opts, :endpoint_source, :env)

    case source do
      :env ->
        opts

      :local ->
        Keyword.merge(opts, cdp_endpoint: "", attach_only: false)

      {:provider, provider} ->
        Keyword.merge(opts, LemonBrowser.ProviderProbe.driver_options(provider))

      :explicit ->
        :explicit
    end
  end

  # The endpoint reaches the driver only through its environment: argv is
  # readable by every local user through `ps` and `/proc/<pid>/cmdline`.
  # Inherited Lemon settings and credentials (relay/operator tokens, hosted
  # provider keys) are unset so neither the driver nor a Chrome it launches
  # receives them.
  @driver_env ~w(LEMON_BROWSER_CDP_PORT LEMON_BROWSER_HEADLESS LEMON_BROWSER_NO_SANDBOX
                 LEMON_BROWSER_EXECUTABLE LEMON_BROWSER_USER_DATA_DIR
                 LEMON_BROWSER_PROFILE_DIRECTORY LEMON_CHROME_EXECUTABLE)
  @secret_env ~r/TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL/i
  @provider_env ~r/^(BROWSERBASE|BROWSER_USE|FIRECRAWL|CAMOFOX)_/i

  defp driver_env(opts) do
    endpoint = configured_endpoint(opts)
    summary = driver_config_summary(opts)

    # A browser Lemon did not launch is not bound to the driver's egress proxy,
    # so the driver refuses to attach unless this is set: by the operator
    # (LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS) or by a hosted provider session,
    # whose browser egresses from the provider's network, not this host.
    allow_unenforced? =
      Keyword.get(opts, :allow_unenforced_egress, Env.get(:lemon_browser_allow_unenforced_egress)) ==
        true

    explicit = [
      {"LEMON_BROWSER_CDP_ENDPOINT", if(endpoint == "", do: false, else: endpoint)},
      {"LEMON_BROWSER_ATTACH_ONLY", if(summary.attach_only, do: "true", else: "false")},
      {"LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS", if(allow_unenforced?, do: "true", else: "false")}
    ]

    unset =
      for {name, _value} <- System.get_env(),
          name not in [
            "LEMON_BROWSER_CDP_ENDPOINT",
            "LEMON_BROWSER_ATTACH_ONLY",
            "LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS"
          ],
          withheld_env?(name),
          do: {name, false}

    Enum.map(unset ++ explicit, fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp withheld_env?(name) do
    name not in @driver_env and
      (String.starts_with?(name, "LEMON_") or Regex.match?(@secret_env, name) or
         Regex.match?(@provider_env, name))
  end

  defp find_node do
    case System.find_executable("node") do
      nil -> {:error, "node executable not found on PATH"}
      path -> {:ok, path}
    end
  end

  defp find_driver(opts) do
    override =
      Keyword.get(opts, :driver_path) ||
        Env.get(:lemon_browser_driver_path) |> to_string_safe()

    if override != "" do
      expanded = Path.expand(override)

      if File.exists?(expanded) do
        {:ok, expanded}
      else
        {:error, "LEMON_BROWSER_DRIVER_PATH does not exist: #{expanded}"}
      end
    else
      candidates = [bundled_driver_path(), source_driver_path()]

      case Enum.find(candidates, &File.exists?/1) do
        nil ->
          {:error,
           "Local browser driver not found. Reinstall Lemon, set LEMON_BROWSER_DRIVER_PATH, " <>
             "or in a source checkout run: npm --prefix clients/lemon-browser-node install && " <>
             "npm --prefix clients/lemon-browser-node run build"}

        path ->
          {:ok, path}
      end
    end
  end

  # Runtime releases stage the built driver and its production dependencies here.
  defp bundled_driver_path do
    Path.join([to_string(:code.priv_dir(:lemon_browser)), "driver", "local-driver.js"])
  end

  defp source_driver_path do
    Path.join(
      LemonCore.Runtime.Env.lemon_root(),
      "clients/lemon-browser-node/dist/local-driver.js"
    )
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n", trim: false)

    case Enum.split(parts, -1) do
      {lines, [last]} ->
        trimmed =
          lines
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {trimmed, last}

      _ ->
        {[], buffer}
    end
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = msg} when is_binary(id) ->
        {entry, pending} = Map.pop(state.pending, id)

        if entry do
          _ = Process.cancel_timer(entry.timer)

          reply =
            case msg do
              %{"ok" => true, "result" => result} ->
                {:ok, result}

              %{"ok" => false, "code" => "outcome_unknown"} ->
                {:error, :outcome_unknown}

              %{"ok" => false, "code" => "not_started"} ->
                {:error, "Browser request timed out before it started"}

              %{"ok" => false, "code" => "timeout"} ->
                {:error, "Browser request timed out"}

              %{"ok" => false, "error" => error} ->
                {:error, redact_urls(to_string(error))}

              _ ->
                unanswered_reply(entry, "Malformed driver response")
            end

          GenServer.reply(entry.from, reply)

          state =
            case reply do
              {:ok, _} ->
                %{state | completed_count: state.completed_count + 1}

              {:error, reason} ->
                state
                |> Map.update!(:failed_count, &(&1 + 1))
                |> remember_error(reason)
            end

          %{state | pending: pending}
        else
          %{state | pending: pending}
        end

      {:ok, _} ->
        state

      {:error, _} ->
        state
    end
  end

  # A request in flight when its driver exits may have run: only a read-only
  # one is reported as a plain failure.
  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, entry} ->
      _ = Process.cancel_timer(entry.timer)
      GenServer.reply(entry.from, unanswered_reply(entry, reason))
    end)

    state
    |> Map.merge(%{pending: %{}, failed_count: state.failed_count + map_size(state.pending)})
    |> remember_error(reason)
  end

  defp unanswered_reply(%{read_only: true}, reason), do: {:error, reason}
  defp unanswered_reply(_entry, _reason), do: {:error, :outcome_unknown}

  defp status_from_state(state) do
    port_info =
      if is_port(state.port) do
        %{
          os_pid: port_info_value(state.port, :os_pid),
          connected: inspect(port_info_value(state.port, :connected))
        }
      else
        nil
      end

    %{
      available: true,
      running: is_port(state.port),
      port: port_info,
      pending_requests: map_size(state.pending),
      buffer_bytes: byte_size(state.buffer),
      request_count: state.request_count,
      completed_count: state.completed_count,
      failed_count: state.failed_count,
      driver_config: state.driver_config || status_config(state.driver_opts),
      started_at: state.started_at,
      last_request_at: state.last_request_at,
      last_error: error_summary(state.last_error),
      last_error_at: state.last_error_at
    }
  end

  defp port_info_value(port, key) do
    case Port.info(port, key) do
      {^key, value} -> value
      _ -> nil
    end
  end

  # Status feeds support bundles, so the driver's error text (which can carry
  # page URLs with tokens in their paths, selectors and ids) is reduced to a
  # fixed category and a hash that still tells repeats apart.
  defp error_summary(nil), do: nil

  defp error_summary(error) do
    %{
      category: error_category(String.downcase(error)),
      hash: LemonCore.Doctor.Redaction.hash(error)
    }
  end

  defp error_category(error) do
    cond do
      error == "outcome_unknown" -> "outcome_unknown"
      error =~ "timed out" or error =~ "timeout" -> "timeout"
      error =~ "driver_path" or error =~ "driver" -> "driver"
      error =~ "selector" -> "selector"
      error =~ "navigat" or error =~ "net::" -> "navigation"
      true -> "other"
    end
  end

  defp remember_error(state, reason) do
    %{state | last_error: redact_urls(to_string(reason)), last_error_at: now_iso8601()}
  end

  defp status_config(driver_opts) do
    case resolve_driver_opts(driver_opts) do
      :explicit -> nil
      opts -> driver_config_summary(opts)
    end
  end

  @url ~r/\b[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^\s"'<>]+/

  @doc false
  # Driver and Chrome errors can echo a CDP URL. Userinfo, fragments and every
  # query value are removed before an error is replied, stored or reported.
  def redact_urls(text) when is_binary(text) do
    Regex.replace(@url, text, fn url ->
      uri = URI.parse(url)
      query = uri.query && redact_query(uri.query)
      URI.to_string(%{uri | userinfo: nil, fragment: nil, query: query})
    end)
  end

  defp redact_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", fn pair -> hd(String.split(pair, "=", parts: 2)) <> "=redacted" end)
  end

  defp driver_args(opts) do
    []
    |> maybe_append_arg(
      configured_profile(opts, :user_data_dir) != "",
      "--user-data-dir",
      configured_profile(opts, :user_data_dir)
    )
    |> maybe_append_arg(
      configured_profile(opts, :profile_directory) != "",
      "--profile-directory",
      configured_profile(opts, :profile_directory)
    )
  end

  defp maybe_append_arg(args, true, flag, value), do: args ++ [flag, value]
  defp maybe_append_arg(args, false, _flag, _value), do: args

  defp configured_endpoint(opts) do
    case Keyword.get(opts, :cdp_endpoint) do
      value when is_binary(value) -> value
      _ -> Env.get(:lemon_browser_cdp_endpoint) |> to_string_safe()
    end
  end

  defp configured_profile(opts, key) do
    env_key =
      case key do
        :user_data_dir -> :lemon_browser_user_data_dir
        :profile_directory -> :lemon_browser_profile_directory
      end

    to_string_safe(
      Keyword.get(opts, key) || Env.get(env_key) || Application.get_env(:lemon_browser, key)
    )
  end

  defp driver_config_summary(opts) do
    endpoint = configured_endpoint(opts)

    attach_only? =
      Keyword.get(opts, :attach_only, Env.get(:lemon_browser_attach_only)) == true or
        endpoint != ""

    # Note: intentionally not `Env.get/2` -- LEMON_BROWSER_CDP_PORT only
    # accepts *positive* integers (0/negative fall back to the default),
    # which is stricter than the standard :integer cast's "any parseable
    # integer" behavior.
    cdp_port = Env.string("LEMON_BROWSER_CDP_PORT") |> parse_positive_int(18_800)

    %{
      mode: if(endpoint == "", do: "local_cdp", else: "remote_cdp"),
      launches_browser: endpoint == "" and not attach_only?,
      attach_only: attach_only?,
      cdp_port: if(endpoint == "", do: cdp_port, else: nil),
      cdp_endpoint_configured: endpoint != "",
      cdp_endpoint_hash: if(endpoint == "", do: nil, else: hash_value(endpoint)),
      profile_identity_hash:
        hash_value(
          Jason.encode!([
            configured_profile(opts, :user_data_dir),
            configured_profile(opts, :profile_directory)
          ])
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp parse_positive_int(_value, fallback), do: fallback

  defp hash_value(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
