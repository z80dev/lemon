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
    with {:ok, operation} <- parse(args),
         :ok <- supported_launcher(operation, opts) do
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
         {:ok, backend, installed} <- backend_environment(opts),
         opts <- bind_backend_environment(backend, opts),
         {:ok, opts} <- controller_options(backend, installed, opts),
         {:ok, env_file} <- read_env(opts),
         {:ok, operator} <- read_operator(backend, opts),
         {:ok, plan} <- plan(mode, existing, backend, env_file, operator, opts),
         {:ok, route_ready} <- route_ready?(plan, opts) do
      env_text = merged_env(plan, env_file, opts)

      same =
        not is_nil(existing) and existing["phase"] == "active" and
          env_text == env_file.text and route_ready and
          canonical(backend["LEMON_BOT_PUBLIC_URL"]) == plan["origin"] and
          member?(operator.origins, plan["origin"])

      with :ok <- if(same, do: :ok, else: write_state(plan, opts)),
           :ok <- ensure_route(plan, opts),
           :ok <- write_env(env_text, opts),
           :ok <- approve_private_mcp(plan, operator),
           :ok <- if(same, do: :ok, else: configure_services(plan["origin"], opts)),
           :ok <- verify_identity(plan["origin"], opts),
           :ok <- controller_check(plan["origin"], opts),
           :ok <- verify_mcp_policy(plan["origin"], backend, opts),
           :ok <- verify_running_policy(plan["origin"], true, opts),
           :ok <- write_state(Map.put(plan, "phase", "active"), opts),
           {:ok, result} <- status(Keyword.put(opts, :bot_public_url, plan["origin"])) do
        {:ok, Map.put(result, :changed, not same)}
      end
    end
  end

  defp change(:disable, opts) do
    with {:ok, state} <- read_state(opts) do
      if is_nil(state) do
        with {:ok, result} <- status(opts), do: {:ok, Map.put(result, :changed, false)}
      else
        with {:ok, backend, installed} <- backend_environment(opts),
             opts <- bind_backend_environment(backend, opts),
             {:ok, opts} <- controller_options(backend, installed, opts),
             {:ok, env_file} <- read_env(opts),
             {:ok, operator} <- read_operator(backend, opts),
             :ok <- remove_owned_route(state, opts),
             :ok <- remove_owned_origins(state, env_file, opts),
             :ok <- remove_private_mcp(state, operator),
             :ok <- configure_services(state["public_url"]["original"], opts),
             :ok <- verify_restored_policy(state["public_url"]["original"], backend, opts),
             :ok <- File.rm(state_path(opts)),
             {:ok, result} <-
               status(Keyword.put(opts, :bot_public_url, state["public_url"]["original"])) do
          {:ok, Map.put(result, :changed, true)}
        end
      end
    end
  end

  defp plan(mode, state, backend, file, operator, opts) do
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
           "schema" => 2,
           "phase" => "pending",
           "added" => additions,
           "backend_env" =>
             if(state,
               do: state["backend_env"],
               else:
                 Map.take(
                   backend,
                   ~w(LEMON_BOT_PORT LEMON_BOT_HOST LEMON_BOT_DATA_DIR LEMON_BOT_CONFIG_FILE LEMON_BOT_CONTROL_URL LEMON_CONTROL_PLANE_PORT)
                 )
             ),
           "public_url" =>
             if(state,
               do: state["public_url"],
               else: %{"original" => previous, "owned" => previous in [nil, ""]}
             ),
           "private_mcp" =>
             if(state,
               do: state["private_mcp"],
               else: %{
                 "path" => operator.path,
                 "added" => not member?(operator.origins, origin),
                 "field_existed" => Map.has_key?(operator.raw, "approvedPrivateMcpOrigins"),
                 "file_existed" => operator.existed
               }
             )
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

  defp supported_launcher(:status, _opts), do: :ok

  defp supported_launcher(_operation, opts) do
    env = Keyword.get(opts, :env, System.get_env())
    source_root = Role.launcher(opts) |> Path.dirname() |> Path.dirname()

    if env["LEMON_CLI_LAUNCHER"] == "source" or File.regular?(Path.join(source_root, "mix.exs")),
      do:
        {:error,
         "Managed HTTPS is not supported by source-mode startup. Follow docs/getting-started/lemon-bot.md#appendix-manual-https-setup and configure the source controller's environment explicitly."},
      else: :ok
  end

  defp bind_backend_environment(backend, opts) do
    opts
    |> Keyword.put_new(:launcher_controller_port, Role.port("controller", opts))
    |> Keyword.put(:backend_process_env, backend)
  end

  defp matching_credential_endpoint(uri, opts) do
    launcher_port = Keyword.get(opts, :launcher_controller_port, Role.port("controller", opts))

    if uri.port == launcher_port do
      :ok
    else
      {:error,
       "The selected controller uses a different port from the launcher's managed credential. Set LEMON_CONTROL_PLANE_PORT=#{uri.port} when invoking lemon bot https so the launcher loads that endpoint's credential; no settings were changed."}
    end
  end

  defp controller_options(backend, installed, opts) do
    with {:ok, desired} <- resolve_controller_options(backend, opts),
         {:ok, current} <-
           if(is_nil(installed),
             do: {:ok, desired},
             else: resolve_controller_options(installed, opts)
           ) do
      desired_uri = URI.parse(desired[:controller_url])
      current_uri = URI.parse(current[:controller_url])
      endpoint_keys = [:scheme, :host, :port, :path]

      if Map.take(desired_uri, endpoint_keys) == Map.take(current_uri, endpoint_keys) do
        with :ok <- matching_credential_endpoint(current_uri, opts),
             :ok <- matching_credential_endpoint(desired_uri, opts),
             do: {:ok, desired}
      else
        {:error,
         "`lemon bot https` doesn't change the controller. Installed and desired endpoints differ; change it with `lemon service install` first, or retain the installed endpoint by invoking HTTPS with LEMON_CONTROL_PLANE_PORT=#{current_uri.port} and no controller-URL override. No settings were changed."}
      end
    end
  end

  defp resolve_controller_options(backend, opts) do
    explicit =
      backend["LEMON_BOT_CONTROL_URL"] not in [nil, ""] or
        backend["LEMON_BOT_OPERATOR_TOKEN"] not in [nil, ""]

    choice_path = Path.join(data_dir(backend, opts), "controller.json")

    with {:ok, choice} <-
           if(explicit, do: {:ok, nil}, else: read_private(choice_path, nil, 65_536)),
         {:ok, choice} <- if(is_binary(choice), do: Jason.decode(choice), else: {:ok, choice}) do
      cond do
        is_map(choice) and choice["mode"] == "remote" ->
          {:error,
           "The Bot uses a saved remote controller. Managed HTTPS cannot configure or verify that remote controller; use the manual HTTPS appendix on the backend and its actual controller."}

        choice != nil and choice != %{"version" => 1, "mode" => "local"} ->
          {:error,
           "The Bot's saved controller choice cannot be resolved safely; inspect it with lemon-bot --choose-lemon."}

        true ->
          port = backend["LEMON_CONTROL_PLANE_PORT"] || to_string(Role.port("controller", opts))
          url = backend["LEMON_BOT_CONTROL_URL"] || "ws://127.0.0.1:#{port}/ws"

          with {:ok, uri} <- URI.new(url),
               true <-
                 uri.scheme in ["ws", "wss"] and uri.host in ["127.0.0.1", "::1", "localhost"],
               true <-
                 uri.path == "/ws" and is_nil(uri.userinfo) and is_nil(uri.query) and
                   is_nil(uri.fragment),
               true <- is_integer(uri.port) and uri.port in 1..65_535 do
            {:ok,
             opts |> Keyword.put(:controller_url, url) |> Keyword.put(:controller_port, uri.port)}
          else
            {:error, message} ->
              {:error, message}

            _ ->
              {:error,
               "The Bot uses a remote controller or unsupported controller endpoint. Managed HTTPS refuses to restart or verify a different local controller; use the manual HTTPS appendix."}
          end
      end
    else
      _ ->
        {:error,
         "The Bot's actual controller configuration is unavailable; refusing to use a different local controller."}
    end
  end

  defp data_dir(backend, opts),
    do: backend["LEMON_BOT_DATA_DIR"] || Path.join([Role.home(opts), ".lemon", "lemon_bot"])

  defp read_operator(backend, opts) do
    path = backend["LEMON_BOT_CONFIG_FILE"] || Path.join(data_dir(backend, opts), "config.json")

    with true <- Role.absolute_safe?(path),
         {:ok, contents} <- read_private(path, nil, 1_048_576),
         {:ok, raw} <- if(contents, do: Jason.decode(contents), else: {:ok, %{"version" => 1}}),
         true <- is_map(raw),
         origins <- Map.get(raw, "approvedPrivateMcpOrigins", []),
         true <- is_list(origins) and Enum.all?(origins, &is_binary/1) do
      {:ok, %{path: path, raw: raw, origins: origins, existed: not is_nil(contents)}}
    else
      _ -> {:error, "The existing backend operator configuration cannot be updated safely."}
    end
  end

  defp approve_private_mcp(plan, operator) do
    if plan["private_mcp"]["path"] != operator.path do
      {:error,
       "The backend operator configuration path changed; refusing to modify another file."}
    else
      if member?(operator.origins, plan["origin"]) do
        :ok
      else
        raw =
          Map.put(operator.raw, "approvedPrivateMcpOrigins", operator.origins ++ [plan["origin"]])

        atomic_preserving(operator.path, Jason.encode!(raw) <> "\n")
      end
    end
  end

  defp remove_private_mcp(state, operator) do
    ownership = state["private_mcp"]

    cond do
      ownership["path"] != operator.path ->
        {:error,
         "The backend operator configuration path changed; refusing to modify another file."}

      not ownership["added"] ->
        :ok

      true ->
        kept = Enum.reject(operator.origins, &(canonical(&1) == state["origin"]))

        raw =
          if not ownership["field_existed"] and kept == [],
            do: Map.delete(operator.raw, "approvedPrivateMcpOrigins"),
            else: Map.put(operator.raw, "approvedPrivateMcpOrigins", kept)

        if not ownership["file_existed"] and raw == %{"version" => 1},
          do: if(operator.existed, do: File.rm(operator.path), else: :ok),
          else: atomic_preserving(operator.path, Jason.encode!(raw) <> "\n")
    end
  end

  defp route_ready?(%{"mode" => "url"}, _opts), do: {:ok, true}

  defp route_ready?(plan, opts) do
    with {:ok, routes} <- command_json(["tailscale", "serve", "status", "--json"], opts),
         do: {:ok, owned_route?(routes, plan)}
  end

  defp verify_mcp_policy(origin, backend, opts) do
    policy =
      Keyword.get(opts, :mcp_policy, fn address, options ->
        command_json(
          [bot_executable(options), "https-policy", "--origin", address, "--json"],
          Keyword.put(options, :command_env, backend_command_env(backend, address, options))
        )
      end)

    pin_opts =
      case Keyword.fetch(opts, :mcp_resolver) do
        {:ok, resolver} -> [resolver: resolver]
        :error -> []
      end

    with {:ok,
          %{
            "origin" => ^origin,
            "allowedOrigins" => [^origin],
            "approvedPrivateOrigins" => [^origin]
          }} <- policy.(origin, opts),
         {:ok, _} <-
           OriginPolicy.pin(
             origin <> "/mcp",
             %{allowed_origins: [origin], approved_private_origins: [origin]},
             pin_opts
           ) do
      :ok
    else
      _ ->
        {:error,
         "The backend's first-party MCP policy did not permit execution at this HTTPS origin. Inspect its operator configuration and DNS before retrying."}
    end
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
    controller_opts = Keyword.put(opts, :port, Keyword.fetch!(opts, :controller_port))

    backend_env =
      Keyword.get(opts, :env, System.get_env())
      |> Map.put("LEMON_CONTROL_PLANE_PORT", to_string(opts[:controller_port]))

    backend_opts =
      opts
      |> Keyword.put(:env, backend_env)
      |> Keyword.put(:bot_public_url, origin)
      |> Keyword.put(:restart_backend, true)

    with :ok <- ready(install.(["controller"], controller_opts)),
         :ok <- restart_controller(controller_opts),
         :ok <- ready(install.(["backend"], backend_opts)) do
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

  defp verify_running_policy(origin, expected_approval, opts) do
    get = Keyword.get(opts, :http_get, &http_get/1)

    with {:ok,
          %{
            "product" => "lemon_bot",
            "publicUrl" => public,
            "firstPartyMcpApproved" => ^expected_approval
          }} <- get.(loopback(opts) <> "/v1/setup"),
         true <- canonical(public) == origin do
      :ok
    else
      _ ->
        {:error,
         "The running backend has not loaded the expected public URL and first-party MCP approval. Its HTTPS receipt remains pending; inspect the backend service restart before retrying."}
    end
  end

  defp verify_restored_policy(original, backend, opts) do
    origin = if original in [nil, ""], do: loopback(opts), else: canonical(original)

    with {:ok, operator} <- read_operator(backend, opts) do
      uri = URI.parse(origin)

      approval =
        member?(operator.origins, origin) or
          (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"])

      verify_running_policy(origin, approval, opts)
    end
  end

  defp controller_check(origin, opts) do
    check =
      Keyword.get(opts, :controller_check, fn canonical ->
        request = Keyword.get(opts, :rpc, &LemonCli.ControlPlaneClient.request/3)
        rpc_opts = [url: Keyword.fetch!(opts, :controller_url), timeout_ms: 30_000]

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
         {:ok, backend, installed} <- backend_environment(opts),
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
        case controller_options(backend, installed, opts) do
          {:ok, resolved} ->
            if address && controller_check(address, resolved) == :ok,
              do: "allowed",
              else: "not confirmed"

          _ ->
            "not confirmed"
        end

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
        with {:ok, env} <- read.(), do: {:ok, env, env}

      {:ok, env} ->
        {:ok, env, env}

      :error ->
        case Service.install_spec("backend", opts) do
          {:ok, spec} ->
            {:ok, spec.env, spec.installed_env}

          _ ->
            {:error,
             "The backend service environment cannot be resolved safely through the service installer."}
        end
    end
  end

  defp backend_status(opts) do
    with {:ok, saved, _installed} <- backend_environment(opts) do
      bot = bot_executable(opts)

      env = backend_command_env(saved, opts[:bot_public_url], opts)

      with {:ok, output} <-
             command(
               [bot, "readdress", "--status", "--json"],
               Keyword.put(opts, :command_env, env)
             ),
           {:ok, report} when is_map(report) <- Jason.decode(output),
           do: {:ok, report}
    end
  end

  defp backend_command_env(saved, origin, opts) do
    env =
      Map.take(saved, ~w(LEMON_BOT_DATA_DIR LEMON_BOT_PORT LEMON_BOT_CONFIG_FILE))
      |> Map.put("HOME", Role.home(opts))
      |> Map.put("BUN_RUNTIME_TRANSPILER_CACHE_PATH", "0")

    if origin, do: Map.put(env, "LEMON_BOT_PUBLIC_URL", origin), else: env
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

  defp merged_env(plan, file, opts) do
    values =
      Map.new(@allowlists, fn key ->
        originals = entries(file, key, opts)

        items =
          Enum.reduce([loopback(opts), plan["origin"]], originals, fn origin, acc ->
            if member?(acc, origin), do: acc, else: acc ++ [origin]
          end)

        {key, Enum.join(items, ",")}
      end)

    replace_env(file.text, values)
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
                "schema" => 2,
                "origin" => origin,
                "mode" => mode,
                "added" => added,
                "phase" => phase
              } = state} <- Jason.decode(contents),
             {:ok, ^origin} <- OriginPolicy.canonical_https_origin(origin),
             true <- mode in ["url", "tailscale"] and phase in ["pending", "active"],
             true <- valid_ownership?(state, origin),
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

  defp valid_ownership?(state, origin) do
    public = state["public_url"]
    private = state["private_mcp"]

    is_map(public) and is_boolean(public["owned"]) and
      public["owned"] == public["original"] in [nil, ""] and
      (public["original"] in [nil, ""] or canonical(public["original"]) == origin) and
      is_map(private) and Role.absolute_safe?(private["path"]) and
      Enum.all?(~w(added field_existed file_existed), &is_boolean(private[&1]))
  end

  defp read_private(path, absent, limit) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> File.read(path)
      {:error, :enoent} -> {:ok, absent}
      _ -> {:error, "HTTPS settings must be bounded regular files, not links or special files."}
    end
  end

  defp write_state(state, opts), do: atomic(state_path(opts), Jason.encode!(state) <> "\n")
  defp write_env(text, opts), do: atomic_preserving(env_path(opts), text)

  defp atomic_preserving(path, contents) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> atomic(path, contents, Bitwise.band(mode, 0o7777))
      {:error, :enoent} -> atomic(path, contents, 0o600)
      _ -> {:error, "Refusing to replace a linked or non-regular configuration file."}
    end
  end

  defp atomic(path, contents, mode \\ 0o600) do
    if File.read(path) == {:ok, contents} do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- Unit.atomic_write(path, contents, mode),
           do: :ok
    end
  end

  defp state_path(opts), do: Path.join([Role.home(opts), ".lemon", @state_file])
  defp env_path(opts), do: Path.join([Role.home(opts), ".lemon", "env"])

  defp loopback(opts) do
    port =
      case opts[:backend_process_env] do
        %{"LEMON_BOT_PORT" => port} -> port
        _ -> Role.port("backend", opts)
      end

    "http://127.0.0.1:#{port}"
  end

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
