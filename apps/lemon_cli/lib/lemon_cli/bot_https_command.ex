defmodule LemonCli.BotHttpsCommand do
  @moduledoc "Manages the Bot service address, owned Tailscale route, and callback allowlists."
  alias LemonCore.Service
  alias LemonCore.Service.{Lock, Role, Unit}
  alias LemonCli.Doctor.BotAdmission
  alias LemonMCP.HTTP.OriginPolicy

  @allowlists ~w(LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS LEMON_CRON_ADMISSION_ALLOWED_ORIGINS)
  @state_file "bot-https.json"

  def cli(args) do
    if Enum.any?(args, &(&1 in ["--help", "-h", "help"])) do
      run(args)
      0
    else
      case parse(args) do
        {:error, message} ->
          IO.puts(:stderr, "Error: #{message}")
          2

        {:ok, _} ->
          if(run(args) == :ok, do: 0, else: 1)
      end
    end
  end

  def run(args, opts \\ []) do
    if Enum.any?(args, &(&1 in ["--help", "-h", "help"])) do
      IO.write(LemonCli.CommandRegistry.help("bot"))
      :ok
    else
      case execute(args, opts) do
        {:ok, result} ->
          render(result)
          :ok

        {:error, message} ->
          IO.puts(:stderr, "Error: #{message}")
          {:error, message}
      end
    end
  end

  def execute(args, opts \\ []) do
    with {:ok, operation} <- parse(args) do
      if operation == :status do
        status(opts)
      else
        lock = Keyword.get(opts, :lock, fn fun -> Lock.with_lock("bot-https", opts, fun) end)

        case lock.(fn -> change(operation, opts) end) do
          {:error, message} when not is_binary(message) ->
            {:error,
             "HTTPS settings are locked or unavailable; no concurrent changes are allowed."}

          result ->
            result
        end
      end
    end
  rescue
    _ ->
      {:error,
       "HTTPS configuration failed. Run lemon bot https status before trying again; no credentials were displayed."}
  end

  defp parse(["status"]), do: {:ok, :status}
  defp parse(["disable"]), do: {:ok, :disable}
  defp parse(["enable", "--tailscale"]), do: {:ok, {:enable, :tailscale}}

  defp parse(["enable", "--url", url]) do
    case OriginPolicy.canonical_https_origin(url) do
      {:ok, origin} ->
        {:ok, {:enable, {:url, origin}}}

      _ ->
        {:error, "--url must be an HTTPS origin without credentials, path, query, or fragment."}
    end
  end

  defp parse(_),
    do: {:error, "Use lemon bot https enable --tailscale|--url HTTPS_ORIGIN, status, or disable."}

  defp change({:enable, mode}, opts) do
    with {:ok, existing} <- read_state(opts),
         {:ok, backend} <- backend_environment(opts),
         {:ok, env_file} <- read_env(opts),
         {:ok, plan} <- plan(mode, existing, backend, env_file, opts),
         :ok <- write_state(plan, opts),
         :ok <- ensure_route(plan, opts),
         {:ok, env_changed} <- merge_env(plan, env_file, opts) do
      same =
        not is_nil(existing) and existing["phase"] == "active" and not env_changed and
          canonical(backend["LEMON_BOT_PUBLIC_URL"]) == plan["origin"]

      with :ok <- if(same, do: :ok, else: configure_services(plan["origin"], opts)),
           :ok <- verify_identity(plan["origin"], opts),
           :ok <- controller_check(plan["origin"], opts),
           :ok <- write_state(Map.put(plan, "phase", "active"), opts),
           {:ok, result} <- status(opts) do
        {:ok, Map.put(result, :changed, not same)}
      end
    end
  end

  defp change(:disable, opts) do
    with {:ok, state} <- read_state(opts) do
      if is_nil(state) do
        with {:ok, result} <- status(opts), do: {:ok, Map.put(result, :changed, false)}
      else
        with {:ok, env_file} <- read_env(opts),
             :ok <- remove_owned_route(state, opts),
             :ok <- remove_owned_origins(state, env_file, opts),
             :ok <- configure_services(nil, opts),
             :ok <- File.rm(state_path(opts)),
             {:ok, result} <- status(opts) do
          {:ok, Map.merge(result, %{address: nil, changed: true})}
        end
      end
    end
  end

  defp plan(mode, state, backend, file, opts) do
    with {:ok, address} <- address(mode, state, opts),
         :ok <- compatible(state, address),
         :ok <- require_loopback_backend(backend) do
      origin = address["origin"]

      additions =
        if state,
          do: state["added"],
          else:
            Map.new(@allowlists, fn key ->
              {key, if(member?(entries(file, key, opts), origin), do: [], else: [origin])}
            end)

      previous = backend["LEMON_BOT_PUBLIC_URL"]

      if is_nil(state) and is_binary(previous) and previous != "" and
           canonical(previous) != origin do
        {:error,
         "The Bot service already has another public address. Remove its manual configuration before enabling managed HTTPS."}
      else
        {:ok,
         Map.merge(address, %{
           "schema" => 1,
           "phase" => if(state, do: state["phase"], else: "pending"),
           "added" => additions
         })}
      end
    end
  end

  defp require_loopback_backend(backend) do
    if Map.get(backend, "LEMON_BOT_HOST", "127.0.0.1") in ["127.0.0.1", "localhost"],
      do: :ok,
      else:
        {:error,
         "Managed HTTPS requires the Bot service to bind 127.0.0.1. Restore its loopback listener before continuing."}
  end

  defp compatible(nil, _), do: :ok

  defp compatible(state, address) do
    if Map.take(state, ["origin", "mode", "port"]) ==
         Map.take(address, ["origin", "mode", "port"]),
       do: :ok,
       else:
         {:error, "Disable the current managed HTTPS address before choosing another address."}
  end

  defp address({:url, origin}, _state, _opts),
    do: {:ok, %{"origin" => origin, "mode" => "url", "port" => nil}}

  defp address(:tailscale, %{"mode" => "tailscale"} = state, _opts),
    do: {:ok, Map.take(state, ["origin", "mode", "port", "target"])}

  defp address(:tailscale, _state, opts) do
    with {:ok, node} <- command_json(["tailscale", "status", "--json"], opts),
         true <- node["BackendState"] == "Running",
         dns when is_binary(dns) <- get_in(node, ["Self", "DNSName"]),
         host <- String.trim_trailing(dns, "."),
         {:ok, _} <- OriginPolicy.canonical_https_origin("https://#{host}"),
         {:ok, routes} <- command_json(["tailscale", "serve", "status", "--json"], opts),
         port when is_integer(port) <- Enum.find(8443..8543, &(not route_port_used?(routes, &1))) do
      {:ok,
       %{
         "origin" => "https://#{String.downcase(host)}:#{port}",
         "mode" => "tailscale",
         "port" => port,
         "target" => loopback(opts)
       }}
    else
      _ ->
        {:error,
         "Tailscale is missing, signed out, or has no free HTTPS route (8443–8543). Install/sign in to Tailscale and enable HTTPS certificates, then retry."}
    end
  end

  defp route_port_used?(routes, port) do
    Map.has_key?(routes["TCP"] || %{}, to_string(port)) or
      Enum.any?(Map.keys(routes["Web"] || %{}), &String.ends_with?(&1, ":#{port}"))
  end

  defp route_target(routes, state) do
    uri = URI.parse(state["origin"])
    get_in(routes, ["Web", "#{uri.host}:#{state["port"]}", "Handlers", "/", "Proxy"])
  end

  defp owned_route?(routes, state) do
    uri = URI.parse(state["origin"])
    key = "#{uri.host}:#{state["port"]}"
    expected = %{"Handlers" => %{"/" => %{"Proxy" => state["target"]}}}

    get_in(routes, ["Web", key]) == expected and
      Enum.count(Map.keys(routes["Web"] || %{}), &String.ends_with?(&1, ":#{state["port"]}")) == 1
  end

  defp ensure_route(%{"mode" => "url"}, _opts), do: :ok

  defp ensure_route(state, opts) do
    with {:ok, routes} <- command_json(["tailscale", "serve", "status", "--json"], opts) do
      cond do
        owned_route?(routes, state) ->
          :ok

        route_port_used?(routes, state["port"]) ->
          {:error,
           "The managed Tailscale port has been changed by another operator; refusing to overwrite it."}

        true ->
          case command(
                 ["tailscale", "serve", "--bg", "--https=#{state["port"]}", state["target"]],
                 opts
               ) do
            {:ok, _} ->
              :ok

            _ ->
              {:error,
               "Tailscale Serve could not be confirmed. Inspect lemon bot https status; the command does not reset other routes."}
          end
      end
    end
  end

  defp remove_owned_route(%{"mode" => "url"}, _opts), do: :ok

  defp remove_owned_route(state, opts) do
    with {:ok, routes} <- command_json(["tailscale", "serve", "status", "--json"], opts) do
      cond do
        not route_port_used?(routes, state["port"]) ->
          :ok

        not owned_route?(routes, state) ->
          {:error,
           "The managed Tailscale route changed; refusing to remove someone else's route."}

        true ->
          case command(["tailscale", "serve", "--https=#{state["port"]}", "off"], opts) do
            {:ok, _} ->
              :ok

            _ ->
              {:error,
               "Could not disable the managed Tailscale route. Inspect its status before retrying."}
          end
      end
    end
  end

  defp configure_services(origin, opts) do
    install = Keyword.get(opts, :service_install, &Service.install/2)

    with :ok <- ready(install.(["controller"], opts)),
         :ok <- restart_controller(opts),
         :ok <- ready(install.(["backend"], Keyword.put(opts, :bot_public_url, origin))) do
      :ok
    else
      _ ->
        {:error,
         "The controller or Lemon Bot service did not become ready. Run lemon service status; HTTPS ownership is retained for recovery or disable."}
    end
  end

  defp ready({:ok, %{units: units}}) when units != [] do
    if Enum.all?(units, &(&1[:state] in ["ready", "online"])), do: :ok, else: {:error, :not_ready}
  end

  defp ready(_), do: {:error, :not_ready}

  defp restart_controller(opts) do
    restart =
      Keyword.get(opts, :controller_restart, fn options ->
        case Service.running_units(options) do
          units when is_list(units) ->
            controllers =
              Enum.filter(
                units,
                &(&1.role == "controller" and &1.spec.port == Role.port("controller", options))
              )

            if controllers == [],
              do: {:error, :controller_missing},
              else: Service.restart_units(controllers, options)

          _ ->
            {:error, :unavailable}
        end
      end)

    restart.(opts)
  end

  defp verify_identity(origin, opts) do
    get = Keyword.get(opts, :http_get, &http_get/1)

    with {:ok, %{"product" => "lemon_bot", "instanceId" => id}} when is_binary(id) and id != "" <-
           get.(loopback(opts) <> "/v1/setup"),
         {:ok, %{"product" => "lemon_bot", "instanceId" => ^id}} <- get.(origin <> "/v1/setup") do
      :ok
    else
      _ ->
        {:error,
         "The HTTPS address did not serve the same Lemon Bot instance as loopback. Check the proxy target and TLS certificate, then run enable again."}
    end
  end

  defp controller_check(origin, opts) do
    check =
      Keyword.get(opts, :controller_check, fn canonical ->
        request = Keyword.get(opts, :rpc, &LemonCli.ControlPlaneClient.request/3)
        rpc_opts = [url: "ws://127.0.0.1:#{Role.port("controller", opts)}/ws", timeout_ms: 30_000]

        case request.("doctor.run", %{"botPublicUrl" => canonical}, rpc_opts) do
          {:ok, %{"botPublicOrigin" => ^canonical, "checks" => checks}} ->
            if Enum.any?(
                 checks,
                 &(&1["name"] == "bot.admission_origins" and &1["status"] == "pass")
               ), do: :ok, else: {:error, :not_allowed}

          _ ->
            {:error, :unavailable}
        end
      end)

    case check.(origin) do
      :ok ->
        :ok

      _ ->
        {:error,
         "The controller has not confirmed both callback allowlists. Run lemon doctor and lemon service status; check environment overrides before retrying."}
    end
  end

  defp status(opts) do
    with {:ok, state} <- read_state(opts),
         {:ok, backend} <- backend_environment(opts),
         {:ok, file} <- read_env(opts) do
      address = if state, do: state["origin"], else: canonical(backend["LEMON_BOT_PUBLIC_URL"])

      allowed =
        Map.new(
          @allowlists,
          &{&1,
           if(address, do: member?(entries(file, &1, opts), canonical(address)), else: false)}
        )

      route =
        case state do
          %{"mode" => "tailscale"} ->
            case command_json(["tailscale", "serve", "status", "--json"], opts) do
              {:ok, routes} ->
                if(route_target(routes, state) == state["target"],
                  do: "#{state["port"]} → #{state["target"]}",
                  else: "missing or changed"
                )

              _ ->
                "unavailable"
            end

          _ ->
            "not managed"
        end

      bot_status = Keyword.get(opts, :backend_status, &backend_status/1)

      bots =
        case bot_status.(Keyword.put(opts, :bot_public_url, address)) do
          {:ok, report} ->
            report

          _ ->
            %{
              "status" => "unavailable",
              "bots" => [],
              "guidance" =>
                "Bot admission status unavailable; open Lemon Bot > each Bot > Settings > Update address."
            }
        end

      controller =
        if address && controller_check(address, opts) == :ok, do: "allowed", else: "not confirmed"

      {:ok,
       %{
         address: address,
         phase: if(state, do: state["phase"], else: "unmanaged"),
         tailscale: route,
         allowlists: allowed,
         controller: controller,
         bots: bots
       }}
    end
  end

  defp backend_environment(opts) do
    case Keyword.fetch(opts, :backend_env) do
      {:ok, read} when is_function(read, 0) ->
        read.()

      {:ok, env} ->
        {:ok, env}

      :error ->
        {manager, _, _} = Service.manager(opts)
        port = Role.port("backend", opts)
        path = Role.unit_path(Role.label("backend", manager, nil, port), manager, opts)

        case Unit.read(path, manager) do
          {:ok, parsed} -> {:ok, parsed.env}
          {:error, :not_found} -> {:ok, %{}}
          _ -> {:error, "The existing Bot service definition cannot be read safely."}
        end
    end
  end

  defp backend_status(opts) do
    with {:ok, saved} <- backend_environment(opts) do
      bot = bot_executable(opts)

      env =
        Map.take(
          Map.merge(Keyword.get(opts, :env, System.get_env()), saved),
          ~w(HOME LEMON_BOT_DATA_DIR LEMON_BOT_PORT)
        )

      env =
        if opts[:bot_public_url],
          do: Map.put(env, "LEMON_BOT_PUBLIC_URL", opts[:bot_public_url]),
          else: env

      with {:ok, output} <-
             command(
               [bot, "readdress", "--status", "--json"],
               Keyword.put(opts, :command_env, env)
             ),
           {:ok, report} when is_map(report) <- Jason.decode(output),
           do: {:ok, report}
    end
  end

  defp bot_executable(opts) do
    Keyword.get_lazy(opts, :bot, fn ->
      {manager, _, _} = Service.manager(opts)
      port = Role.port("backend", opts)
      path = Role.unit_path(Role.label("backend", manager, nil, port), manager, opts)

      case Unit.read(path, manager) do
        {:ok, parsed} ->
          Keyword.get(
            Role.options_from_argv(parsed.argv),
            :bot,
            Path.join([Role.home(opts), ".local/bin/lemon-bot"])
          )

        _ ->
          Path.join([Role.home(opts), ".local/bin/lemon-bot"])
      end
    end)
  end

  defp entries(file, key, opts) do
    env = Keyword.get(opts, :env, System.get_env())

    {app, config} =
      if key == "LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS",
        do: {:lemon_router, :native_followup_allowed_origins},
        else: {:lemon_automation, :cron_admission_allowed_origins}

    fallback = Application.get_env(app, config, []) |> Enum.join(",")

    Map.get(file.values, key, Map.get(env, key, fallback))
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp merge_env(plan, file, opts) do
    values =
      Map.new(@allowlists, fn key ->
        originals = entries(file, key, opts)

        items =
          Enum.reduce([loopback(opts), plan["origin"]], originals, fn origin, acc ->
            if member?(acc, origin), do: acc, else: acc ++ [origin]
          end)

        {key, Enum.join(items, ",")}
      end)

    text = replace_env(file.text, values)

    if text == file.text,
      do: {:ok, false},
      else: with(:ok <- write_env(text, opts), do: {:ok, true})
  end

  defp remove_owned_origins(state, file, opts) do
    values =
      Map.new(@allowlists, fn key ->
        removed = get_in(state, ["added", key]) || []
        kept = Enum.reject(entries(file, key, opts), fn entry -> canonical(entry) in removed end)
        kept = if member?(kept, loopback(opts)), do: kept, else: kept ++ [loopback(opts)]
        {key, Enum.join(kept, ",")}
      end)

    write_env(replace_env(file.text, values), opts)
  end

  defp replace_env(text, values) do
    Enum.reduce(values, text, fn {key, value}, acc ->
      pattern = ~r/^[ \t]*(?:export[ \t]+)?#{key}=.*$/m
      replacement = "export #{key}='#{value}'"

      if Regex.match?(pattern, acc) do
        Regex.replace(pattern, acc, fn _ -> replacement end)
      else
        separator = if acc == "" or String.ends_with?(acc, "\n"), do: "", else: "\n"
        acc <> separator <> replacement <> "\n"
      end
    end)
  end

  defp read_env(opts) do
    with {:ok, text} <- read_private(env_path(opts), "", 1_048_576) do
      Enum.reduce_while(@allowlists, {:ok, %{text: text, values: %{}}}, fn key, {:ok, acc} ->
        case Regex.scan(~r/^[ \t]*(?:export[ \t]+)?#{key}=(.*)$/m, text) do
          [] ->
            {:cont, {:ok, acc}}

          [[_, raw]] ->
            case env_value(String.trim(raw)) do
              {:ok, value} ->
                {:cont, {:ok, %{acc | values: Map.put(acc.values, key, value)}}}

              _ ->
                {:halt,
                 {:error,
                  "An admission allowlist in ~/.lemon/env is not a literal comma-separated value; resolve it manually before continuing."}}
            end

          _ ->
            {:halt,
             {:error,
              "Duplicate admission allowlist assignments in ~/.lemon/env; consolidate them before continuing."}}
        end
      end)
    end
  end

  defp env_value(raw) do
    value =
      case raw do
        <<"'", rest::binary>> ->
          if String.ends_with?(rest, "'"),
            do: String.slice(rest, 0, byte_size(rest) - 1),
            else: nil

        <<"\"", rest::binary>> ->
          if String.ends_with?(rest, "\""),
            do: String.slice(rest, 0, byte_size(rest) - 1),
            else: nil

        _ ->
          raw
      end

    if is_binary(value) and not Regex.match?(~r/[\s'"$`\\\x00-\x1F]/, value),
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp read_state(opts) do
    with {:ok, contents} <- read_private(state_path(opts), nil, 65_536) do
      if is_nil(contents) do
        {:ok, nil}
      else
        with {:ok,
              %{
                "schema" => 1,
                "origin" => origin,
                "mode" => mode,
                "added" => added,
                "phase" => phase
              } = state} <- Jason.decode(contents),
             {:ok, ^origin} <- OriginPolicy.canonical_https_origin(origin),
             true <- mode in ["url", "tailscale"] and phase in ["pending", "active"],
             true <-
               is_map(added) and
                 Enum.all?(@allowlists, fn key ->
                   is_list(added[key]) and Enum.all?(added[key], &(&1 == origin))
                 end),
             true <-
               mode == "url" or
                 (is_integer(state["port"]) and state["port"] in 1..65_535 and
                    state["target"] == loopback(opts)) do
          {:ok, state}
        else
          _ ->
            {:error,
             "The HTTPS ownership receipt is invalid; refusing to guess which settings or routes to remove."}
        end
      end
    end
  end

  defp read_private(path, absent, limit) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> File.read(path)
      {:error, :enoent} -> {:ok, absent}
      _ -> {:error, "HTTPS settings must be bounded regular files, not links or special files."}
    end
  end

  defp write_state(state, opts), do: atomic(state_path(opts), Jason.encode!(state) <> "\n")
  defp write_env(text, opts), do: atomic(env_path(opts), text)

  defp atomic(path, contents) do
    if File.read(path) == {:ok, contents} do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- Unit.atomic_write(path, contents, 0o600),
           do: :ok
    end
  end

  defp state_path(opts), do: Path.join([Role.home(opts), ".lemon", @state_file])
  defp env_path(opts), do: Path.join([Role.home(opts), ".lemon", "env"])
  defp loopback(opts), do: "http://127.0.0.1:#{Role.port("backend", opts)}"

  defp canonical(value) do
    case BotAdmission.origin(value) do
      {:ok, origin} -> origin
      _ -> nil
    end
  end

  defp member?(entries, origin),
    do: is_binary(origin) and Enum.any?(entries, &(canonical(&1) == origin))

  defp command(argv, opts) do
    runner =
      Keyword.get(opts, :command, fn args, options ->
        case LemonCore.Secrets.SourceRunner.run(args,
               timeout_ms: 30_000,
               max_output_bytes: 262_144,
               env: Keyword.get(options, :command_env, %{})
             ) do
          {:ok, %{output: output}} -> {:ok, output}
          _ -> {:error, :command_failed}
        end
      end)

    runner.(argv, opts)
  end

  defp command_json(argv, opts) do
    with {:ok, output} <- command(argv, opts),
         {:ok, result} when is_map(result) <- Jason.decode(output),
         do: {:ok, result}
  end

  defp http_get(url) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist(url), []},
             [
               timeout: 10_000,
               connect_timeout: 5_000,
               autoredirect: false,
               ssl: [
                 verify: :verify_peer,
                 cacerts: :public_key.cacerts_get(),
                 customize_hostname_check: [
                   match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                 ]
               ]
             ],
             body_format: :binary
           ),
         true <- byte_size(body) <= 65_536,
         {:ok, result} when is_map(result) <- Jason.decode(body) do
      {:ok, result}
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp render(result) do
    IO.puts("Address: #{result.address || "loopback only"} (#{result.phase})")
    IO.puts("Tailscale: #{result.tailscale}")
    IO.puts("Controller admission: #{result.controller}")

    for key <- @allowlists,
        do: IO.puts("#{key}: #{if result.allowlists[key], do: "allowed", else: "not allowed"}")

    bots = Enum.take(result.bots["bots"] || [], 200)
    IO.puts("Bots (saved local admission snapshot):")

    for bot <- bots do
      id =
        bot["id"] |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "") |> String.slice(0, 128)

      name =
        bot["name"]
        |> to_string()
        |> String.replace(~r/[\x00-\x1F\x7F-\x9F]|\e\[[0-9;]*[A-Za-z]/u, "")
        |> String.slice(0, 120)

      label = if name == "", do: id, else: "#{name} (#{id})"

      state =
        if bot["admissionState"] in ~w(configured pending rejected outcome_unknown missing unknown),
          do: bot["admissionState"],
          else: "unknown"

      IO.puts(
        "Bot #{label}: #{state}#{if bot["nextAction"] == "update_address", do: " — Update address", else: ""}"
      )
    end

    affected = Enum.filter(bots, &(&1["nextAction"] == "update_address"))

    if affected != [] do
      IO.puts(
        "ACTION REQUIRED: #{length(affected)} listed Bot(s) cannot reply at the new address until their owners update them."
      )

      IO.puts(
        "For each named Bot above: sign in as its owner → open the Bot → Settings → lifecycle panel → Update address."
      )
    end

    if Enum.any?(bots, &(&1["nextAction"] not in [nil, "none", "update_address"])) do
      IO.puts(
        "For interrupted or uncertain work: open the Bot → Settings → lifecycle panel → Check status (or Finish setup when offered). Never repeat an outcome_unknown mutation."
      )
    end

    if result.bots["status"] == "unavailable",
      do:
        IO.puts(
          "Bot admission status unavailable; open Lemon Bot's Bots list and inspect Settings → lifecycle panel for each Bot."
        )

    if result.bots["truncated"] do
      count =
        case result.bots["totalBots"] do
          n when is_integer(n) and n > length(bots) -> Integer.to_string(n - length(bots))
          _ -> "Additional"
        end

      IO.puts("#{count} more Bots may also need Update address; see the Bots list.")
    end
  end
end
