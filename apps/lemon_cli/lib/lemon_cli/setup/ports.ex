defmodule LemonCli.Setup.Ports do
  @moduledoc """
  Runtime port selection and persistence for `lemon setup`.

  The runtime reads its ports from `LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT`,
  `LEMON_SIM_UI_PORT` and `LEMON_CONTROL_PLANE_NODE_PORT`. Launchers load
  `~/.lemon/ports.env` into whichever of those are unset and export them, so a
  port chosen here reaches the daemon, the TUI and one-shot CLI commands, while
  an explicit environment value still wins.

  Setup checks only the ports the selected runtime profile binds by default:
  the control plane, plus the web UI for profiles that include `:lemon_web`.
  The node gateway default (4044) is reserved next to 4040/4080 and persisted
  in `~/.lemon/ports.env` when a different port is chosen.
  """

  alias LemonCore.Paths
  alias LemonCore.Runtime.Profile

  @type key :: :control | :web | :sim | :node
  @type ports :: %{
          optional(:control) => pos_integer(),
          optional(:node) => non_neg_integer(),
          optional(:web) => pos_integer(),
          optional(:sim) => pos_integer()
        }

  @file_name "ports.env"
  @search_span 100
  @default_node_port 4044
  @node_var "LEMON_CONTROL_PLANE_NODE_PORT"
  @vars [control: "LEMON_CONTROL_PLANE_PORT", web: "LEMON_WEB_PORT", sim: "LEMON_SIM_UI_PORT"]

  @doc "Default port for the node gateway (4044)."
  @spec default_node_port() :: pos_integer()
  def default_node_port, do: @default_node_port

  @doc "Path of the persisted port file, `~/.lemon/ports.env` by default."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    Keyword.get_lazy(opts, :ports_path, fn ->
      Path.join(Paths.home_state_dir(), @file_name)
    end)
  end

  @doc "Ports a profile binds by default, in prompt order."
  @spec required(atom()) :: [key()]
  def required(profile) do
    if profile in Profile.names() and :lemon_web in Profile.app_list(profile),
      do: [:control, :node, :web],
      else: [:control, :node]
  end

  @doc "Human label for a port key."
  @spec label(key()) :: String.t()
  def label(:control), do: "control plane"
  def label(:node), do: "node gateway"
  def label(:web), do: "web UI"
  def label(:sim), do: "sim UI"

  @doc """
  Whether nothing listens on `port` on loopback and Lemon could bind it there.
  """
  @spec free?(pos_integer()) :: boolean()
  def free?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _reason} ->
        case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false]) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            true

          {:error, _reason} ->
            false
        end
    end
  end

  @doc """
  The first port after `port` (within #{@search_span}) that is free and not in
  `reserved`, or `nil`. Automatically reserves the node gateway port (4044)
  unless `port` is the node gateway port itself.
  """
  @spec suggest(pos_integer(), [pos_integer()], (pos_integer() -> boolean())) ::
          pos_integer() | nil
  def suggest(port, reserved, free? \\ &free?/1) do
    effective_reserved =
      if port == @default_node_port,
        do: reserved,
        else: Enum.uniq([@default_node_port | reserved])

    (port + 1)..min(port + @search_span, 65_535)//1
    |> Enum.find(&(&1 not in effective_reserved and free?.(&1)))
  end

  @doc """
  Persists `ports` and applies them to this process's environment, so a TUI or
  daemon started from it uses them too.

  `LEMON_CONTROL_PLANE_NODE_PORT` is persisted only when `node` is present and
  differs from the 4044 default; `0` (explicitly disabled) is persisted as `0`.
  """
  @spec save(ports(), keyword()) :: {:ok, String.t()} | {:error, File.posix()}
  def save(ports, opts \\ []) do
    file = path(opts)

    base_lines =
      Enum.flat_map(@vars, fn {key, var} ->
        case Map.fetch(ports, key) do
          {:ok, val} -> ["#{var}=#{val}\n"]
          :error -> []
        end
      end)

    node_port = Map.get(ports, :node)

    node_lines =
      if is_integer(node_port) and node_port >= 0 and node_port != @default_node_port do
        ["#{@node_var}=#{node_port}\n"]
      else
        []
      end

    content = IO.iodata_to_binary(base_lines ++ node_lines)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, content) do
      Enum.each(@vars, fn {key, var} ->
        if val = Map.get(ports, key) do
          System.put_env(var, Integer.to_string(val))
        end
      end)

      if is_integer(node_port) and node_port >= 0 and node_port != @default_node_port do
        System.put_env(@node_var, Integer.to_string(node_port))
      end

      {:ok, file}
    end
  end
end
