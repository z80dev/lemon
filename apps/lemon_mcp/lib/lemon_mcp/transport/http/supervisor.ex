defmodule LemonMCP.Transport.HTTP.Supervisor do
  @moduledoc false

  use Supervisor

  alias LemonMCP.Server
  alias LemonMCP.Transport.HTTP
  alias LemonMCP.Transport.HTTP.RegistryMember

  @server_child_id LemonMCP.Server
  @bandit_child_id {LemonMCP.Transport.HTTP, :bandit}
  @registry_child_id {LemonMCP.Transport.HTTP, :registry_member}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc false
  @spec server_pid(Supervisor.supervisor()) :: pid() | nil
  def server_pid(supervisor) when is_pid(supervisor) do
    child_pid(supervisor, @server_child_id)
  end

  def server_pid(_supervisor), do: nil

  @doc false
  @spec bandit_pid(Supervisor.supervisor()) :: pid() | nil
  def bandit_pid(supervisor) when is_pid(supervisor) do
    child_pid(supervisor, @bandit_child_id)
  end

  def bandit_pid(_supervisor), do: nil

  @doc false
  @spec registry_member_pid(Supervisor.supervisor()) :: pid() | nil
  def registry_member_pid(supervisor) when is_pid(supervisor) do
    child_pid(supervisor, @registry_child_id)
  end

  def registry_member_pid(_supervisor), do: nil

  @impl true
  def init(opts) do
    server_opts = build_server_opts(opts)
    generation = System.unique_integer([:monotonic, :positive])

    bandit_opts = [
      plug: {HTTP, mcp_supervisor: self()},
      ip: Keyword.fetch!(opts, :ip),
      port: Keyword.fetch!(opts, :port),
      scheme: :http
    ]

    children = [
      Supervisor.child_spec(
        {RegistryMember, supervisor: self(), generation: generation},
        id: @registry_child_id
      ),
      Supervisor.child_spec({Server, server_opts}, id: @server_child_id),
      Supervisor.child_spec({Bandit, bandit_opts}, id: @bandit_child_id)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp child_pid(supervisor, child_id) do
    Enum.find_value(Supervisor.which_children(supervisor), fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  defp build_server_opts(opts) do
    [
      server_name: Keyword.get(opts, :server_name, "Lemon MCP Server"),
      server_version: Keyword.get(opts, :server_version, "0.1.0"),
      tool_provider: Keyword.get(opts, :tool_provider),
      tools: Keyword.get(opts, :tools),
      tool_handler: Keyword.get(opts, :tool_handler),
      resources: Keyword.get(opts, :resources),
      resource_handler: Keyword.get(opts, :resource_handler),
      prompts: Keyword.get(opts, :prompts),
      prompt_handler: Keyword.get(opts, :prompt_handler)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
