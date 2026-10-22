defmodule LemonCli.Setup.Ports do
  @moduledoc """
  Runtime port selection and persistence for `lemon setup`.

  The runtime reads its ports from `LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT`
  and `LEMON_SIM_UI_PORT`. Launchers load `~/.lemon/ports.env` into whichever
  of those are unset and export them, so a port chosen here reaches the daemon,
  the TUI and one-shot CLI commands, while an explicit environment value still
  wins.

  Setup checks only the ports the selected runtime profile binds by default:
  the control plane, plus the web UI for profiles that include `:lemon_web`.
  """

  alias LemonCore.Paths
  alias LemonCore.Runtime.Profile

  @type key :: :control | :web | :sim
  @type ports :: %{control: pos_integer(), web: pos_integer(), sim: pos_integer()}

  @file_name "ports.env"
  @search_span 100
  @vars [control: "LEMON_CONTROL_PLANE_PORT", web: "LEMON_WEB_PORT", sim: "LEMON_SIM_UI_PORT"]

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
      do: [:control, :web],
      else: [:control]
  end

  @doc "Human label for a port key."
  @spec label(key()) :: String.t()
  def label(:control), do: "control plane"
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
  `reserved`, or `nil`.
  """
  @spec suggest(pos_integer(), [pos_integer()], (pos_integer() -> boolean())) ::
          pos_integer() | nil
  def suggest(port, reserved, free? \\ &free?/1) do
    (port + 1)..min(port + @search_span, 65_535)//1
    |> Enum.find(&(&1 not in reserved and free?.(&1)))
  end

  @doc """
  Persists `ports` and applies them to this process's environment, so a TUI or
  daemon started from it uses them too.
  """
  @spec save(ports(), keyword()) :: {:ok, String.t()} | {:error, File.posix()}
  def save(ports, opts \\ []) do
    file = path(opts)

    content =
      Enum.map_join(@vars, fn {key, var} -> "#{var}=#{Map.fetch!(ports, key)}\n" end)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, content) do
      Enum.each(@vars, fn {key, var} ->
        System.put_env(var, Integer.to_string(Map.fetch!(ports, key)))
      end)

      {:ok, file}
    end
  end
end
