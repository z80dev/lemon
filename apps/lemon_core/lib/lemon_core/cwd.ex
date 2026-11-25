defmodule LemonCore.Cwd do
  @moduledoc """
  Shared default working-directory resolver for gateway and channels runtimes.

  Two defaults exist:

    * `default_cwd/0` — for local, operator-initiated runs (control plane,
      cron, background work): configured `gateway.default_cwd`, then the
      user's home directory, then the process cwd.
    * `channel_default_cwd/0` — for runs that originate from a messaging
      channel (Telegram, Discord, …): configured `gateway.default_cwd`, then
      the assistant home (`assistant_home/0`). Remote chats never default to
      the user's `$HOME`.
  """

  require Logger

  @spec default_cwd() :: String.t()
  def default_cwd do
    case configured_default_cwd() |> normalize_existing_dir() do
      nil -> home_or_process_cwd()
      cwd -> cwd
    end
  end

  @doc """
  Default working directory for channel-originated runs.

  Uses the configured `gateway.default_cwd` when it names an existing
  directory; otherwise the assistant home, which is created on demand.
  """
  @spec channel_default_cwd() :: String.t()
  def channel_default_cwd do
    case configured_default_cwd() |> normalize_existing_dir() do
      nil -> ensure_assistant_home()
      cwd -> cwd
    end
  end

  @doc """
  The assistant home directory: `<agent_dir>/workspace`.

  `agent_dir` follows the agent's own resolution order: `LEMON_AGENT_DIR`,
  then `config :coding_agent, :agent_dir`, then `~/.lemon/agent`.
  """
  @spec assistant_home() :: String.t()
  def assistant_home do
    agent_dir =
      non_blank(System.get_env("LEMON_AGENT_DIR")) ||
        non_blank(Application.get_env(:coding_agent, :agent_dir)) ||
        LemonCore.Paths.home_path("agent")

    agent_dir
    |> Path.join("workspace")
    |> Path.expand()
  end

  defp ensure_assistant_home do
    home = assistant_home()

    case File.mkdir_p(home) do
      :ok ->
        home

      {:error, reason} ->
        fallback = File.cwd!()

        Logger.warning(
          "Could not create assistant home #{home} (#{inspect(reason)}); " <>
            "channel runs fall back to #{fallback}"
        )

        fallback
    end
  end

  defp configured_default_cwd, do: LemonCore.GatewayConfig.get(:default_cwd)

  defp home_or_process_cwd do
    case System.user_home() |> normalize_existing_dir() do
      nil -> File.cwd!()
      cwd -> cwd
    end
  rescue
    _ -> File.cwd!()
  end

  defp normalize_existing_dir(path) when is_binary(path) do
    path = String.trim(path)

    if path == "" do
      nil
    else
      expanded = Path.expand(path)
      if File.dir?(expanded), do: expanded, else: nil
    end
  end

  defp normalize_existing_dir(_), do: nil

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_blank(_), do: nil
end
