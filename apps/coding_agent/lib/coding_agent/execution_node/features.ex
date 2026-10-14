defmodule CodingAgent.ExecutionNode.Features do
  @moduledoc """
  Installed worker software/API compatibility, separate from provider login,
  configured bot policy and measured OS permissions. A matching CalVer alone
  never proves that an unpublished/source worker contains the required APIs.
  """
  alias CodingAgent.ExecutionNode.HostCommand

  @host_methods ~w(node.host.info node.capabilities.get node.runtime.features node.fs.list node.fs.stat node.fs.read node.fs.write node.fs.mkdir node.fs.move node.fs.delete.preview node.fs.delete)
  @secret_methods ~w(node.secrets.set node.secrets.list node.secrets.delete node.secrets.receipt)
  @shell_methods ~w(node.shell.open node.shell.input node.shell.resize node.shell.close)

  def snapshot(capabilities, opts \\ []) when is_map(capabilities) do
    supported_platform = Keyword.get(opts, :platform, :os.type()) in [{:unix, :linux}, {:unix, :darwin}]
    python = Keyword.get_lazy(opts, :python_supported, &python_supported?/0)
    assets = Keyword.get_lazy(opts, :assets, &assets/0)
    native_policy = Keyword.get_lazy(opts, :native_execution_policy, fn ->
      Code.ensure_loaded?(LemonCore.ToolPolicy) and function_exported?(LemonCore.ToolPolicy, :execution_json_opts, 1)
    end)
    secret_receipts = Keyword.get_lazy(opts, :secret_receipts, fn ->
      Code.ensure_loaded?(LemonCore.Secrets) and function_exported?(LemonCore.Secrets, :receipt, 2)
    end)
    features = %{
      "hostIO" => supported_platform and all?(capabilities, @host_methods),
      "filesystemCAS" => supported_platform and python and Map.get(assets, "node_fs.py", false) and
        all?(capabilities, ~w(node.fs.write node.fs.move node.fs.delete.preview)),
      "deletePreviews" => supported_platform and python and Map.get(assets, "node_fs.py", false) and
        all?(capabilities, ~w(node.fs.delete.preview node.fs.delete)),
      "encryptedSecrets" => secret_receipts and all?(capabilities, @secret_methods),
      "ptyShell" => supported_platform and python and Map.get(assets, "node_pty.py", false) and Map.get(assets, "node_fs.py", false) and all?(capabilities, @shell_methods),
      "mcpDiscovery" => supported?(capabilities["node.mcp.discover"]),
      "profileSync" => all?(capabilities, ~w(node.profile.sync node.profile.sync.status node.profile.paths)),
      "liveStreaming" => version(capabilities["coding_agent.run"]) == 1 and
        version(capabilities["node.invoke.event"]) == 1 and valid_stream_bound?(capabilities["node.invoke.event"]),
      "repairInvites" => version(capabilities["node.enrollment"]) == 1 and
        capabilities["node.enrollment"]["repairInvites"] == true,
      "nativeExecutionPolicy" => native_policy
    }
    missing = features |> Enum.filter(fn {_, supported} -> not supported end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    %{"protocol" => 1, "lemonVersion" => LemonCore.Update.Version.current(),
      "methods" => capabilities |> Map.keys() |> List.delete("node.enrollment") |> Enum.sort(), "features" => features,
      "botReady" => missing == [], "missingFeatures" => missing}
  end

  defp all?(capabilities, methods), do: Enum.all?(methods, &supported?(capabilities[&1]))
  defp supported?(true), do: true
  defp supported?(descriptor) when is_map(descriptor), do: version(descriptor) == 1
  defp supported?(_), do: false
  defp version(descriptor) when is_map(descriptor), do: descriptor["version"]
  defp version(_), do: nil
  defp valid_stream_bound?(descriptor) when is_map(descriptor) do
    bytes = descriptor["maxBytes"]
    is_integer(bytes) and bytes > 0 and bytes <= 65_536
  end
  defp valid_stream_bound?(_), do: false

  defp assets do
    case :code.priv_dir(:coding_agent) do
      path when is_list(path) ->
        Map.new(["node_fs.py", "node_pty.py"], &{&1, File.regular?(Path.join(to_string(path), &1))})
      _ -> %{}
    end
  end

  defp python_supported? do
    script = "import json,sys,os,pty,fcntl; print(json.dumps(sys.version_info >= (3,9) and all(hasattr(os,n) for n in ['pread','pwrite','waitstatus_to_exitcode','O_NOFOLLOW'])))"
    case HostCommand.run("python3", ["-c", script]) do
      {:ok, "true"} -> true
      _ -> false
    end
  end
end
