defmodule LemonSkills.GitRemote do
  @moduledoc """
  The one way skill sources run `git` against a remote repository.

    * Remote: an `https://` or `http://` URL without credentials, query or
      fragment, `ssh://[user@]host[:port]/path`, or scp-style `user@host:path`.
      Local paths, `file://`, `git://` and `<transport>::` helper URLs are
      refused (`:invalid_git_url`).
    * Destination: the host is authorized by `LemonCore.Net.Address` (public
      addresses only; metadata never) and git is pinned to the authorized
      address — HTTP(S) through `http.curloptResolve`, SSH through `HostName`
      with `HostKeyAlias` keeping the host-key identity and no proxy, connection
      sharing, local command or agent/X11/port forwarding, whatever the user's
      SSH configuration says. HTTP redirects are not followed. The operator's
      global `[skills] allowed_private_git_hosts` names hosts (exact, case
      insensitive) that may resolve to private addresses; they are still
      pinned and metadata stays refused. Project config cannot set it.
    * Proxies are never used: `http_proxy`/`https_proxy`/`all_proxy` and
      `http.proxy` are cleared, so a remote reachable only through a proxy
      cannot be installed.
    * Environment: every inherited `GIT_*` and proxy variable is removed,
      system and global Git configuration are ignored, and repository
      discovery cannot climb out of a private scratch directory. Only the
      remote's own transport is allowed (`protocol.allow=never`); hooks,
      fsmonitor, askpass, credential helpers and submodules are off, and
      symlinks are checked out as plain files.
    * Bounds: one deadline (`:timeout_ms`, default 120 s) terminates the whole
      process group (`{:error, :timeout}`), and the clone directory is capped
      while it is written (`:max_bytes`, default 64 MiB;
      `{:error, :clone_too_large}`). A failed clone removes its directory.

  `:resolver` (see `LemonCore.Net.Address.resolve/2`) replaces DNS for tests.
  """

  alias LemonCore.Net.{Address, HTTP}
  alias LemonCore.{NativeProcess, ProcessGroup}

  @default_timeout_ms 120_000
  @default_max_bytes 64 * 1024 * 1024
  @poll_ms 100
  @max_output_bytes 16 * 1024
  @max_url_bytes 2_048
  @proxy_variables ~w(http_proxy https_proxy all_proxy no_proxy ftp_proxy)

  @type remote :: %{
          url: String.t(),
          transport: String.t(),
          host: String.t(),
          port: pos_integer(),
          address: :inet.ip_address(),
          literal?: boolean()
        }

  @doc """
  Clones `url` into `dest`. Options: `:branch` (`nil` for the remote HEAD),
  `:depth` (default 1), `:sparse` (blobless sparse clone), plus the bounds.
  """
  @spec clone(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def clone(url, dest, opts \\ []) do
    dest = Path.expand(dest)

    with {:ok, remote} <- authorize(url, opts),
         {:ok, branch_args} <- branch_args(Keyword.get(opts, :branch)) do
      sparse =
        if Keyword.get(opts, :sparse) == true, do: ["--filter=blob:none", "--sparse"], else: []

      args =
        ["clone", "--no-recurse-submodules", "--depth", depth(opts)] ++
          sparse ++ branch_args ++ ["--", remote.url, dest]

      case run(remote, args, opts, dest) do
        {:ok, _output} ->
          :ok

        error ->
          File.rm_rf(dest)
          error
      end
    end
  end

  @doc """
  Runs `git sparse-checkout set --no-cone <patterns>` in a sparse clone of
  `url`, fetching the selected blobs under the same policy and bounds.
  """
  @spec sparse_checkout(String.t(), Path.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def sparse_checkout(url, repo, patterns, opts \\ []) when is_list(patterns) do
    repo = Path.expand(repo)

    with {:ok, remote} <- authorize(url, opts),
         true <- Enum.all?(patterns, &valid_pattern?/1) || {:error, :invalid_sparse_pattern},
         {:ok, _output} <-
           run(remote, ["-C", repo, "sparse-checkout", "set", "--no-cone" | patterns], opts, repo) do
      :ok
    end
  end

  @doc "Returns the commit the remote's `HEAD` points at."
  @spec head(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def head(url, opts \\ []) do
    with {:ok, remote} <- authorize(url, opts),
         {:ok, output} <- run(remote, ["ls-remote", "--", remote.url, "HEAD"], opts, nil) do
      case Regex.run(~r/^([0-9a-f]{40}|[0-9a-f]{64})\tHEAD$/m, output) do
        [_, hash] -> {:ok, hash}
        _ -> {:error, :no_head}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Remote parsing and authorization
  # ---------------------------------------------------------------------------

  @doc false
  @spec authorize(term(), keyword()) :: {:ok, remote()} | {:error, term()}
  def authorize(url, opts) do
    with {:ok, remote} <- parse(url) do
      case Address.parse_literal(remote.host) do
        {:ok, _address} -> pin(remote, true, opts)
        :error -> pin(remote, false, opts)
      end
    end
  end

  defp pin(remote, literal?, opts) do
    address_opts = Keyword.take(opts, [:resolver])

    result =
      case Address.authorize(remote.host, address_opts) do
        {:error, :destination_not_public} = refused ->
          if remote.host in operator_private_hosts(opts),
            do: Address.authorize(remote.host, [allow_private: true] ++ address_opts),
            else: refused

        other ->
          other
      end

    case result do
      {:ok, [address | _]} -> {:ok, Map.merge(remote, %{address: address, literal?: literal?})}
      {:error, :dns_timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  # `[skills] allowed_private_git_hosts` from the operator's global config;
  # `LemonCore.Config.ProjectLayer` drops it from project files. Unreadable
  # config allows nothing.
  defp operator_private_hosts(opts) do
    case LemonCore.Config.load(Keyword.get(opts, :cwd)) do
      %{skills: %{allowed_private_git_hosts: hosts}} when is_list(hosts) ->
        for host <- hosts,
            is_binary(host),
            do: host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp parse(url)
       when is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @max_url_bytes do
    cond do
      Regex.match?(~r/[\x00-\x20\x7f\\#?]/, url) ->
        {:error, :invalid_git_url}

      String.starts_with?(url, ["https://", "http://"]) ->
        parse_http(url)

      String.starts_with?(url, "ssh://") ->
        parse_ssh_url(url)

      true ->
        parse_scp(url)
    end
  end

  defp parse(_url), do: {:error, :invalid_git_url}

  defp parse_http(url) do
    case HTTP.parse_url(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, path: "/" <> _}} ->
        {:ok, %{url: url, transport: scheme, host: host, port: port}}

      _ ->
        {:error, :invalid_git_url}
    end
  end

  defp parse_ssh_url(url) do
    case URI.parse(url) do
      %URI{host: host, port: port, userinfo: user, path: "/" <> _}
      when is_binary(host) and host != "" ->
        if (is_nil(user) or ssh_user?(user)) and host_name?(host) and
             (is_nil(port) or port in 1..65_535),
           do:
             {:ok, %{url: url, transport: "ssh", host: String.downcase(host), port: port || 22}},
           else: {:error, :invalid_git_url}

      _ ->
        {:error, :invalid_git_url}
    end
  end

  # scp-style `user@host:path`; git reads it as SSH because no `/` precedes
  # the first `:`.
  defp parse_scp(url) do
    case Regex.run(~r/\A([^@:\/]+)@([^@:\/]+):([^:]+)\z/, url) do
      [_, user, host, path] ->
        if ssh_user?(user) and host_name?(host) and not String.starts_with?(path, "-"),
          do: {:ok, %{url: url, transport: "ssh", host: String.downcase(host), port: 22}},
          else: {:error, :invalid_git_url}

      _ ->
        {:error, :invalid_git_url}
    end
  end

  defp ssh_user?(user), do: Regex.match?(~r/\A[A-Za-z0-9._][A-Za-z0-9._-]{0,63}\z/, user)

  # A DNS name or IPv4 literal; IPv6 SSH literals are not supported.
  defp host_name?(host),
    do: Regex.match?(~r/\A[A-Za-z0-9_]([A-Za-z0-9_.-]{0,252}[A-Za-z0-9_])?\z/, host)

  defp branch_args(nil), do: {:ok, []}

  defp branch_args(branch) when is_binary(branch) do
    if Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9._\/-]{0,199}\z/, branch) and
         not String.contains?(branch, ".."),
       do: {:ok, ["--branch", branch]},
       else: {:error, :invalid_branch}
  end

  defp branch_args(_branch), do: {:error, :invalid_branch}

  defp valid_pattern?(pattern),
    do: is_binary(pattern) and Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9._\/-]{0,511}\z/, pattern)

  defp depth(opts) do
    case Keyword.get(opts, :depth, 1) do
      depth when is_integer(depth) and depth > 0 -> Integer.to_string(depth)
      _ -> "1"
    end
  end

  # ---------------------------------------------------------------------------
  # Command configuration
  # ---------------------------------------------------------------------------

  @doc false
  @spec config(remote()) :: [{String.t(), String.t()}]
  def config(remote) do
    [
      {"protocol.allow", "never"},
      {"protocol.#{remote.transport}.allow", "always"},
      {"core.symlinks", "false"},
      {"core.hooksPath", "/dev/null"},
      {"core.fsmonitor", "false"},
      {"core.askPass", ""},
      {"credential.helper", ""},
      {"submodule.recurse", "false"},
      {"fetch.recurseSubmodules", "false"},
      {"http.followRedirects", "false"},
      {"http.proxy", ""},
      {"http.sslVerify", "true"}
    ] ++ transport_config(remote)
  end

  defp transport_config(%{transport: "ssh"} = remote) do
    alias = if remote.port == 22, do: remote.host, else: "[#{remote.host}]:#{remote.port}"

    options = [
      "HostName=#{ip(remote.address)}",
      "HostKeyAlias=#{alias}",
      "BatchMode=yes",
      "ProxyCommand=none",
      "ProxyJump=none",
      "ControlMaster=no",
      "ControlPath=none",
      "PermitLocalCommand=no",
      "ForwardAgent=no",
      "ForwardX11=no",
      "ClearAllForwardings=yes"
    ]

    command = Enum.map_join(options, " ", &"-o '#{&1}'")
    [{"ssh.variant", "ssh"}, {"core.sshCommand", "ssh " <> command}]
  end

  defp transport_config(%{literal?: true}), do: []

  defp transport_config(remote) do
    address =
      case remote.address do
        {_, _, _, _} = v4 -> ip(v4)
        v6 -> "[#{ip(v6)}]"
      end

    [{"http.curloptResolve", "#{remote.host}:#{remote.port}:#{address}"}]
  end

  defp ip(address), do: address |> :inet.ntoa() |> to_string()

  @doc false
  @spec env(String.t()) :: [{charlist(), charlist() | false}]
  def env(scratch) do
    removed =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, "GIT_") or String.downcase(name) in @proxy_variables,
          do: {String.to_charlist(name), false}

    removed ++
      [
        {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
        {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
        {~c"GIT_ATTR_NOSYSTEM", ~c"1"},
        {~c"GIT_TERMINAL_PROMPT", ~c"0"},
        {~c"GIT_CEILING_DIRECTORIES", String.to_charlist(Path.dirname(scratch))},
        {~c"GCM_INTERACTIVE", ~c"Never"},
        {~c"LC_ALL", ~c"C"}
      ]
  end

  # ---------------------------------------------------------------------------
  # Bounded execution
  # ---------------------------------------------------------------------------

  # Runs in a task so that port messages never reach the caller's mailbox.
  defp run(remote, args, opts, watch) do
    timeout = positive(Keyword.get(opts, :timeout_ms), @default_timeout_ms)
    max_bytes = positive(Keyword.get(opts, :max_bytes), @default_max_bytes)
    deadline = System.monotonic_time(:millisecond) + timeout

    case System.find_executable("git") do
      nil ->
        {:error, :git_unavailable}

      git ->
        fn -> with_scratch(&execute(git, remote, args, &1, deadline, watch, max_bytes)) end
        |> Task.async()
        |> Task.await(:infinity)
    end
  end

  defp with_scratch(fun) do
    scratch = Path.join(System.tmp_dir!(), "lemon-git-#{System.unique_integer([:positive])}")

    try do
      case File.mkdir(scratch) do
        :ok -> fun.(scratch)
        {:error, _} -> {:error, :git_unavailable}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp execute(git, remote, args, scratch, deadline, watch, max_bytes) do
    config = Enum.flat_map(config(remote), fn {key, value} -> ["-c", "#{key}=#{value}"] end)

    port =
      NativeProcess.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: config ++ args,
        env: env(scratch),
        cd: scratch
      ])

    watcher = %{
      port: port,
      deadline: deadline,
      watch: watch,
      max_bytes: max_bytes,
      tick: make_ref()
    }

    try do
      schedule_scan(watcher)
      await(watcher, [], 0)
    after
      stop(port)
    end
  rescue
    _ -> {:error, :git_unavailable}
  end

  # The size scan runs on its own timer, so a remote that keeps the port busy
  # (sideband progress) cannot postpone it; the deadline bounds the wait for
  # every message and each scan.
  defp await(%{port: port, tick: tick} = watcher, output, size) do
    remaining = watcher.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          {output, size} = keep_output(output, size, data)
          await(watcher, output, size)

        {^port, {:exit_status, status}} ->
          output = output |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

          case scan(watcher) do
            :ok when status == 0 -> {:ok, output}
            :ok -> {:error, {:git_failed, output}}
            error -> error
          end

        {^tick, :scan} ->
          with :ok <- scan(watcher) do
            schedule_scan(watcher)
            await(watcher, output, size)
          end
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp schedule_scan(%{watch: nil}), do: :ok
  defp schedule_scan(%{tick: tick}), do: Process.send_after(self(), {tick, :scan}, @poll_ms)

  # Output past the limit is dropped, not accumulated.
  defp keep_output(output, size, _data) when size >= @max_output_bytes, do: {output, size}

  defp keep_output(output, size, data) do
    kept = binary_part(data, 0, min(byte_size(data), @max_output_bytes - size))
    {[kept | output], size + byte_size(kept)}
  end

  # The process group is terminated whether or not git exited, so helpers it
  # started (ssh, remote-https) never outlive the command.
  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 1 ->
        _ = ProcessGroup.terminate(pid, grace_ms: 500)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp scan(%{watch: nil}), do: :ok

  defp scan(watcher) do
    case tree_bytes([watcher.watch], 0, watcher.max_bytes, watcher.deadline) do
      :timeout -> {:error, :timeout}
      total when total > watcher.max_bytes -> {:error, :clone_too_large}
      _total -> :ok
    end
  end

  # Sums regular-file sizes without following links, stopping past the cap or
  # at the deadline.
  defp tree_bytes([], total, _max_bytes, _deadline), do: total
  defp tree_bytes(_paths, total, max_bytes, _deadline) when total > max_bytes, do: total

  defp tree_bytes([path | rest], total, max_bytes, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          children =
            case File.ls(path) do
              {:ok, names} -> Enum.map(names, &Path.join(path, &1))
              _ -> []
            end

          tree_bytes(children ++ rest, total, max_bytes, deadline)

        {:ok, %File.Stat{size: size}} ->
          tree_bytes(rest, total + size, max_bytes, deadline)

        _ ->
          tree_bytes(rest, total, max_bytes, deadline)
      end
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
