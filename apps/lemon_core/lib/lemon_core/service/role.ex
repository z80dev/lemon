defmodule LemonCore.Service.Role do
  @moduledoc "Service role definitions. Units always execute the machine's stable launchers."

  alias LemonCore.Service.Command

  @roles ~w(controller backend worker tunnel)
  @backend_env ~w(LEMON_BOT_PORT LEMON_BOT_HOST LEMON_BOT_DATA_DIR LEMON_BOT_PUBLIC_URL LEMON_BOT_TRUSTED_OVERLAY)

  def roles, do: @roles
  def fetch(role) when role in @roles, do: {:ok, role}
  def fetch(_), do: :error
  def home(opts), do: Keyword.get(opts, :home, System.user_home!())
  def run_dir(opts), do: Path.join([home(opts), ".lemon", "run", "service"])

  def launcher(opts) do
    stable = Path.join([home(opts), ".lemon", "bin", "lemon"])
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    invoking = Map.get(env, "LEMON_LAUNCHER")

    Keyword.get(opts, :launcher) ||
      cond do
        env["LEMON_CLI_LAUNCHER"] == "source" and is_binary(invoking) -> invoking
        File.exists?(stable) -> stable
        true -> invoking || stable
      end
  end

  def port(role, opts) do
    env = Keyword.get(opts, :env, System.get_env())

    {key, fallback} =
      if role == "controller",
        do: {"LEMON_CONTROL_PLANE_PORT", 4040},
        else: {"LEMON_BOT_PORT", 4100}

    value = Keyword.get(opts, :port) || Map.get(env, key) || saved_port(key, opts)

    case Integer.parse(to_string(value || fallback)) do
      {port, ""} when port in 1..65535 -> port
      _ -> fallback
    end
  end

  def build(role, manager, opts) when role in @roles do
    name = if role in ["worker", "tunnel"], do: Keyword.get(opts, :name), else: nil
    port = if role in ["controller", "backend"], do: port(role, opts), else: nil

    with :ok <- validate(role, manager, opts),
         {:ok, argv} <- arguments(role, opts) do
      label = label(role, manager, name, port)
      log_name = if role == "worker", do: "node", else: role
      log_name = if name, do: log_name <> "-" <> name, else: log_name

      {:ok,
       %{
         role: role,
         name: name,
         label: label,
         port: port,
         argv: argv,
         env: environment(role, manager, opts),
         home: home(opts),
         path: unit_path(label, manager, opts),
         log: Path.join([home(opts), ".lemon", "logs", log_name <> ".log"]),
         options: Keyword.drop(opts, [:command_runner, :invite_code, :http_get, :status_reader])
       }}
    end
  end

  def build(_, _, _), do: {:error, :invalid_role}

  def label(role, "launchd", name, port) do
    case role do
      "controller" -> "org.lemon.controller" <> suffix(port, 4040)
      "backend" -> "org.lemon.bot" <> suffix(port, 4100)
      "worker" -> "org.lemon.node." <> to_string(name)
      "tunnel" -> "org.lemon.tunnel." <> to_string(name)
    end
  end

  def label(role, _, name, port) do
    middle =
      case role do
        "controller" -> "controller" <> suffix(port, 4040, "-")
        "backend" -> "bot" <> suffix(port, 4100, "-")
        "worker" -> "node-" <> to_string(name)
        "tunnel" -> "tunnel-" <> to_string(name)
      end

    "lemon-" <> middle <> ".service"
  end

  def unit_path(label, "launchd", opts),
    do: Path.join([home(opts), "Library", "LaunchAgents", label <> ".plist"])

  def unit_path(label, "systemd", opts),
    do: Path.join([home(opts), ".config", "systemd", "user", label])

  def unit_path(label, "none", opts), do: Path.join(run_dir(opts), label <> ".json")

  def identity(filename) do
    patterns = [
      {~r/^org\.lemon\.controller(?:\.(\d+))?\.plist$/, "controller", 4040},
      {~r/^org\.lemon\.bot(?:\.(\d+))?\.plist$/, "backend", 4100},
      {~r/^lemon-controller(?:-(\d+))?\.service(?:\.json)?$/, "controller", 4040},
      {~r/^lemon-bot(?:-(\d+))?\.service(?:\.json)?$/, "backend", 4100}
    ]

    Enum.find_value(patterns, fn {pattern, role, default} ->
      case Regex.run(pattern, filename) do
        [_, ""] -> {role, [port: default]}
        [_, port] -> {role, [port: String.to_integer(port)]}
        [_] -> {role, [port: default]}
        _ -> nil
      end
    end) || named_identity(filename)
  end

  defp named_identity(filename) do
    case Regex.run(
           ~r/^(?:org\.lemon\.(node|tunnel)\.(.+)\.plist|lemon-(node|tunnel)-(.+)\.service(?:\.json)?)$/,
           filename
         ) do
      [_, kind, name] when kind in ["node", "tunnel"] -> named(kind, name)
      [_, kind, name, "", ""] when kind in ["node", "tunnel"] -> named(kind, name)
      [_, "", "", kind, name] -> named(kind, name)
      _ -> nil
    end
  end

  defp named(kind, name) do
    if valid_name?(name),
      do: {if(kind == "node", do: "worker", else: "tunnel"), [name: name]},
      else: nil
  end

  def options_from_argv([wrapper, "--" | argv]),
    do: [{:exec_wrapper, wrapper} | options_from_argv(argv)]

  def options_from_argv([_launcher, "node", "join" | args]), do: parse_args(args)
  def options_from_argv([_launcher, "tunnel", "run" | args]), do: parse_args(args)
  def options_from_argv([bot, "--no-open" | _]), do: [bot: bot]
  def options_from_argv(_), do: []

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          controller: :string,
          cwd: :string,
          allowed_root: [:string, :keep],
          ssh: :string,
          node_port: :integer,
          gateway_port: :integer,
          product_port: :integer,
          backend_port: :integer
        ]
      )

    opts
  end

  defp validate(role, manager, opts) do
    env = Keyword.get(opts, :env, System.get_env())
    name = Keyword.get(opts, :name)
    wrapper = Keyword.get(opts, :exec_wrapper)

    cond do
      role in ["worker", "tunnel"] and not valid_name?(name) ->
        {:error, :invalid_name}

      role == "backend" and
          Enum.any?(~w(LEMON_BOT_OPERATOR_TOKEN LEMON_BOT_ENCRYPTION_KEY), &Map.has_key?(env, &1)) ->
        {:error, :backend_secret_environment}

      wrapper && manager != "launchd" ->
        {:error, :exec_wrapper_requires_macos}

      wrapper && not (absolute_safe?(wrapper) and String.contains?(wrapper, ".app/")) ->
        {:error, :invalid_exec_wrapper}

      wrapper && not executable?(wrapper) ->
        {:error, :exec_wrapper_missing}

      not absolute_safe?(launcher(opts)) ->
        {:error, :invalid_launcher}

      true ->
        :ok
    end
  end

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/, name)

  def absolute_safe?(path),
    do:
      is_binary(path) and Path.type(path) == :absolute and byte_size(path) <= 4096 and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, path)

  def executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp arguments("controller", opts), do: {:ok, [launcher(opts), "start"]}

  defp arguments("backend", opts) do
    bot = Keyword.get(opts, :bot, Path.join([home(opts), ".local", "bin", "lemon-bot"]))

    if absolute_safe?(bot) and executable?(bot),
      do: {:ok, [bot, "--no-open"]},
      else: {:error, :bot_executable_missing}
  end

  defp arguments("worker", opts) do
    controller = Keyword.get(opts, :controller)
    cwd = Keyword.get(opts, :cwd, home(opts))
    roots = Keyword.get_values(opts, :allowed_root)

    if is_binary(controller) and byte_size(controller) <= 4096 and
         not Regex.match?(~r/[\x00-\x20\x7f]/, controller) and absolute_safe?(cwd) and
         File.dir?(cwd) and Enum.all?(roots, &absolute_safe?/1) do
      argv =
        [
          launcher(opts),
          "node",
          "join",
          "--name",
          opts[:name],
          "--controller",
          controller,
          "--cwd",
          cwd
        ] ++ Enum.flat_map(roots, &["--allowed-root", &1])

      {:ok, if(opts[:exec_wrapper], do: [opts[:exec_wrapper], "--" | argv], else: argv)}
    else
      {:error, :worker_options_required}
    end
  end

  defp arguments("tunnel", opts) do
    # The tunnel runner lands independently; reserve the complete role contract.
    required = [:ssh, :node_port, :gateway_port]

    valid_ports =
      Enum.all?([:node_port, :gateway_port, :product_port, :backend_port], fn key ->
        is_nil(opts[key]) or (is_integer(opts[key]) and opts[key] in 1..65535)
      end)

    destination = opts[:ssh]

    valid_destination =
      is_binary(destination) and
        Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,253}\z/, destination)

    if Enum.all?(required, &Keyword.has_key?(opts, &1)) and valid_ports and valid_destination do
      args =
        Enum.flat_map([:name | required] ++ [:product_port, :backend_port], fn key ->
          if value = opts[key],
            do: ["--" <> String.replace(to_string(key), "_", "-"), to_string(value)],
            else: []
        end)

      {:ok, [launcher(opts), "tunnel", "run" | args]}
    else
      {:error, :tunnel_options_required}
    end
  end

  defp environment(role, manager, opts) do
    source = Keyword.get(opts, :env, System.get_env())

    base = %{
      "HOME" => home(opts),
      "PATH" => login_path(opts, source),
      "LANG" => Map.get(source, "LANG", "en_US.UTF-8"),
      "LEMON_SERVICE_MANAGER" => manager,
      "LEMON_SERVICE_ROLE" => role
    }

    case role do
      "worker" ->
        worker =
          Map.merge(base, %{"LEMON_GATEWAY_HEALTH_PORT" => "0", "LEMON_ROUTER_HEALTH_PORT" => "0"})

        if opts[:exec_wrapper],
          do: Map.put(worker, "LEMON_TCC_PROBE", opts[:exec_wrapper]),
          else: worker

      "backend" ->
        Map.merge(base, Map.take(source, @backend_env))
        |> Map.put("LEMON_BOT_PORT", to_string(port(role, opts)))

      "controller" ->
        Map.put(base, "LEMON_CONTROL_PLANE_PORT", to_string(port(role, opts)))

      "tunnel" ->
        Map.take(Map.merge(source, base), ~w(HOME PATH SSH_AUTH_SOCK))
        |> tunnel_agent(manager, opts)
    end
  end

  defp tunnel_agent(env, "systemd", opts) do
    case Command.run("systemctl", ["--user", "show-environment"], opts) do
      {output, 0} ->
        case Regex.run(~r/^SSH_AUTH_SOCK=(.+)$/m, output) do
          [_, socket] ->
            if absolute_safe?(socket), do: Map.put(env, "SSH_AUTH_SOCK", socket), else: env

          _ ->
            env
        end

      _ ->
        env
    end
  end

  defp tunnel_agent(env, _, _), do: env

  defp login_path(opts, env) do
    inherited =
      Keyword.get_lazy(opts, :login_path, fn ->
        case Command.run(Map.get(env, "SHELL", "/bin/sh"), ["-lc", "printf %s \"$PATH\""], opts,
               timeout: 10_000
             ) do
          {path, 0} -> path
          _ -> Map.get(env, "PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        end
      end)

    [
      Path.dirname(launcher(opts)),
      Path.join(home(opts), ".lemon/bin"),
      Path.join(home(opts), ".local/bin") | String.split(inherited, ":")
    ]
    |> Enum.filter(&absolute_safe?(&1))
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp saved_port(key, opts) do
    case File.read(Path.join(home(opts), ".lemon/ports.env")) do
      {:ok, contents} ->
        case Regex.run(~r/^\s*(?:export\s+)?#{key}=['"]?(\d+)['"]?\s*$/m, contents) do
          [_, port] -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp suffix(value, default, separator \\ "."),
    do: if(value == default, do: "", else: separator <> to_string(value))
end
