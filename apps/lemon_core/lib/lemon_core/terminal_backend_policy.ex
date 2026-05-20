defmodule LemonCore.TerminalBackendPolicy do
  @moduledoc """
  Runtime policy checks for terminal/process backends.
  """

  @backend_allow_env "LEMON_TERMINAL_BACKENDS_ALLOW"
  @backend_deny_env "LEMON_TERMINAL_BACKENDS_DENY"
  @backend_approval_env "LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL"
  @docker_images_env "LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES"
  @ssh_targets_env "LEMON_SSH_TERMINAL_ALLOWED_TARGETS"
  @registered_backend_ids [:local, :local_pty, :docker, :ssh]

  @spec validate(atom()) :: :ok | {:error, term()}
  def validate(backend) when is_atom(backend) do
    with :ok <- validate_backend_list_policy(backend),
         :ok <- validate_backend_specific_policy(backend) do
      :ok
    end
  end

  def validate(_backend), do: {:error, :unknown_backend}

  @spec describe(atom()) :: map()
  def describe(backend) when is_atom(backend) do
    %{
      allowed: validate(backend) == :ok,
      requires_approval: requires_approval?(backend),
      denylisted: backend in backend_denylist(),
      allowlist_configured: backend_allowlist_configured?(),
      denied_backends: backend_denylist(),
      allowed_backends: allowed_backends()
    }
    |> Map.merge(specific_description(backend))
  end

  def describe(_backend) do
    %{
      allowed: false,
      requires_approval: false,
      denylisted: false,
      allowlist_configured: backend_allowlist_configured?(),
      denied_backends: backend_denylist(),
      allowed_backends: allowed_backends()
    }
  end

  @spec diagnostics() :: map()
  def diagnostics do
    %{
      backend_allowlist_configured: backend_allowlist_configured?(),
      allowed_backends: allowed_backends(),
      denied_backends: backend_denylist(),
      approval_required_backends: approval_required_backends(),
      docker: docker_description(),
      ssh: ssh_description()
    }
  end

  @spec requires_approval?(atom()) :: boolean()
  def requires_approval?(backend) when is_atom(backend),
    do: backend in approval_required_backends()

  def requires_approval?(_backend), do: false

  defp validate_backend_list_policy(backend) do
    cond do
      backend in backend_denylist() ->
        {:error, {:terminal_backend_denied, backend}}

      backend_allowlist_configured?() and backend not in backend_allowlist() ->
        {:error, {:terminal_backend_not_allowed, backend}}

      true ->
        :ok
    end
  end

  defp validate_backend_specific_policy(:docker) do
    allowed_images = docker_allowed_images()
    image = LemonCore.TerminalBackends.Docker.image()

    with :ok <- validate_docker_image(image),
         :ok <- validate_docker_network(LemonCore.TerminalBackends.Docker.network()),
         :ok <- validate_size("memory", LemonCore.TerminalBackends.Docker.memory()),
         :ok <- validate_cpu(LemonCore.TerminalBackends.Docker.cpus()),
         :ok <-
           validate_positive_integer("pids_limit", LemonCore.TerminalBackends.Docker.pids_limit()),
         :ok <- validate_size("tmpfs_size", LemonCore.TerminalBackends.Docker.tmpfs_size()) do
      if allowed_images == [] or image in allowed_images do
        :ok
      else
        {:error, {:docker_image_not_allowed, image}}
      end
    end
  end

  defp validate_backend_specific_policy(:ssh) do
    allowed_targets = ssh_allowed_targets()
    target = LemonCore.TerminalBackends.Ssh.target()

    with :ok <- validate_ssh_port(LemonCore.TerminalBackends.Ssh.port()),
         :ok <-
           validate_positive_integer(
             "connect_timeout",
             LemonCore.TerminalBackends.Ssh.connect_timeout_seconds()
           ),
         :ok <-
           validate_strict_host_key_checking(
             LemonCore.TerminalBackends.Ssh.strict_host_key_checking()
           ) do
      cond do
        target == nil ->
          {:error, :ssh_target_not_configured}

        allowed_targets == [] ->
          :ok

        target in allowed_targets ->
          :ok

        true ->
          {:error, :ssh_target_not_allowed}
      end
    end
  end

  defp validate_backend_specific_policy(_backend), do: :ok

  defp specific_description(:docker), do: %{docker: docker_description()}
  defp specific_description(:ssh), do: %{ssh: ssh_description()}
  defp specific_description(_backend), do: %{}

  defp docker_description do
    image = LemonCore.TerminalBackends.Docker.image()
    allowed_images = docker_allowed_images()

    %{
      allowed_images_configured: allowed_images != [],
      allowed_images: allowed_images,
      image_allowed: allowed_images == [] or image in allowed_images,
      pull_policy: :never,
      network: LemonCore.TerminalBackends.Docker.network(),
      read_only_rootfs: LemonCore.TerminalBackends.Docker.read_only_rootfs?(),
      tmpfs: LemonCore.TerminalBackends.Docker.tmpfs_mounts()
    }
  end

  defp ssh_description do
    target = LemonCore.TerminalBackends.Ssh.target()
    allowed_targets = ssh_allowed_targets()

    %{
      allowed_targets_configured: allowed_targets != [],
      allowed_target_hashes: Enum.map(allowed_targets, &hash/1),
      target_allowed: target != nil and (allowed_targets == [] or target in allowed_targets),
      target_hash: if(target, do: hash(target)),
      strict_host_key_checking: LemonCore.TerminalBackends.Ssh.strict_host_key_checking()
    }
  end

  defp allowed_backends do
    case backend_allowlist() do
      [] -> registered_backend_ids() -- backend_denylist()
      allowlist -> allowlist -- backend_denylist()
    end
  end

  defp backend_allowlist_configured?, do: backend_allowlist() != []
  defp backend_allowlist, do: backend_env(@backend_allow_env)
  defp backend_denylist, do: backend_env(@backend_deny_env)
  defp approval_required_backends, do: backend_env(@backend_approval_env)

  defp backend_env(name) do
    name
    |> list_env()
    |> Enum.reduce([], fn id, acc ->
      case normalize_backend_id(id) do
        nil -> acc
        backend -> [backend | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp registered_backend_ids, do: @registered_backend_ids

  defp normalize_backend_id(id) when is_atom(id) and id in @registered_backend_ids, do: id

  defp normalize_backend_id(id) when is_binary(id) do
    normalized =
      id
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.find(@registered_backend_ids, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_backend_id(_id), do: nil

  defp docker_allowed_images, do: list_env(@docker_images_env)
  defp ssh_allowed_targets, do: list_env(@ssh_targets_env)

  defp validate_docker_image(image) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/-]*$/, image) do
      :ok
    else
      {:error, :invalid_docker_image}
    end
  end

  defp validate_docker_network(network) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/, network) do
      :ok
    else
      {:error, :invalid_docker_network}
    end
  end

  defp validate_size(name, value) do
    if Regex.match?(~r/^[1-9][0-9]*(b|k|m|g)?$/i, value) do
      :ok
    else
      {:error, {:invalid_docker_resource_limit, name}}
    end
  end

  defp validate_cpu(value) do
    if Regex.match?(~r/^([1-9][0-9]*|0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*\.[0-9]+)$/, value) do
      :ok
    else
      {:error, {:invalid_docker_resource_limit, "cpus"}}
    end
  end

  defp validate_positive_integer(name, value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> :ok
      _ -> {:error, {:invalid_terminal_integer, name}}
    end
  end

  defp validate_ssh_port(value) do
    case Integer.parse(value) do
      {int, ""} when int in 1..65_535 -> :ok
      _ -> {:error, :invalid_ssh_port}
    end
  end

  defp validate_strict_host_key_checking(value) do
    case value |> to_string() |> String.downcase() do
      value when value in ["yes", "no", "ask", "accept-new"] -> :ok
      _ -> {:error, :invalid_ssh_strict_host_key_checking}
    end
  end

  defp list_env(name) do
    case System.get_env(name) do
      nil ->
        []

      value ->
        value
        |> String.split([",", "\n"], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
