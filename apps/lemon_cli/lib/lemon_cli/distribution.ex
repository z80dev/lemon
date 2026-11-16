defmodule LemonCli.Distribution do
  @moduledoc false

  # OTP 29 has no public API for installing a cookie before distribution starts.
  # Reuse its supervisor spec, changing only auth's start function so the cookie
  # is installed before the following net_kernel child can open a listener.
  # Keep this contract pinned by the real-node launcher regression.
  def boot do
    case node_options() do
      nil ->
        :ok

      options ->
        child = %{
          id: :net_sup_dynamic,
          start: {__MODULE__, :start_link, [options]},
          restart: :permanent,
          shutdown: 1000,
          type: :supervisor
        }

        case :supervisor.start_child(:kernel_sup, child) do
          {:ok, _pid} -> :ok
          _ -> fail!("could not start authenticated distribution")
        end
    end

    if :init.get_argument(:user) == {:ok, [[~c"Elixir.LemonCli.Distribution"]]} do
      :ok = :user_drv.start_shell(%{initial_shell: :iex.shell()})
    end
  end

  # IEx's normal -user elixir starts remsh while kernel itself is still
  # booting. Defer its shell until boot/0 has installed the cookie.
  def start, do: :user_drv.start(%{initial_shell: :noshell, input: :cooked})

  def start_link(options) do
    :supervisor.start_link({:local, :net_sup}, __MODULE__, options)
  end

  def init(options) do
    {flags, children} = distribution_spec!(options)

    children =
      Enum.map(children, fn
        %{id: :auth} = child -> %{child | start: {__MODULE__, :start_auth, []}}
        child -> child
      end)

    {:ok, {flags, children}}
  end

  def distribution_spec!(options) do
    unless :erlang.system_info(:otp_release) == ~c"29" and
             :init.get_argument(:nocookie) == {:ok, [[]]} and
             :application.get_env(:kernel, :start_distribution) == {:ok, false} do
      fail!("requires OTP 29, -nocookie and -kernel start_distribution false")
    end

    case :erl_distribution.init([options]) do
      {:ok, {%{strategy: :one_for_all, intensity: 0} = flags, children}} ->
        case Enum.reverse(children) do
          [
            %{id: :net_kernel, start: {:net_kernel, :start_link, [^options]}},
            %{id: :auth, start: {:auth, :start_link, []}}
            | earlier
          ] ->
            if Enum.any?(earlier, &(&1.id in [:auth, :net_kernel])) do
              fail!("unexpected distribution supervisor children")
            end

            {flags, children}

          _ ->
            fail!("unexpected distribution supervisor children")
        end

      _ ->
        fail!("unexpected distribution supervisor specification")
    end
  end

  def start_auth do
    # No network listener, default HOME cookie, or application connection may
    # precede this step. -nocookie prevents auth from reading/creating that file.
    unless :erlang.whereis(:net_kernel) == :undefined and not Node.alive?() do
      fail!("distribution started before cookie initialization")
    end

    cookie =
      case System.get_env("RELEASE_COOKIE") do
        value when is_binary(value) and value != "" ->
          try do
            String.to_atom(value)
          rescue
            _ -> fail!("invalid distribution cookie")
          end

        _ ->
          fail!("missing distribution cookie")
      end

    with {:ok, pid} <- :auth.start_link() do
      true = :erlang.set_cookie(cookie)
      {:ok, pid}
    end
  end

  defp node_options do
    case {:init.get_argument(:sname), :init.get_argument(:name)} do
      {{:ok, [[name]]}, :error} -> options(name, :shortnames)
      {:error, {:ok, [[name]]}} -> options(name, :longnames)
      {:error, :error} -> nil
      _ -> fail!("expected exactly one distribution node name")
    end
  end

  defp options(name, domain) do
    %{
      name: :erlang.list_to_atom(name),
      name_domain: domain,
      clean_halt: false,
      supervisor: :net_sup_dynamic
    }
  end

  defp fail!(reason) do
    otp = :erlang.system_info(:otp_release)
    raise "Secure distribution boot refused on OTP #{otp}: #{reason}"
  end
end
