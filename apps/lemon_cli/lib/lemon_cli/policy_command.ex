defmodule LemonCli.PolicyCommand do
  @moduledoc """
  Manage chat model and thinking defaults (`LemonCore.PolicyStore` chat rows).

  A row applies to every session of its route: a thread, a peer (chat), an
  account or a whole channel. The most specific row that sets a model (or a
  thinking level) wins; a session's own override (`/model` for this session,
  `sessions.patch`) wins over every chat row.

  ## Usage

      # List all chat defaults
      lemon policy list

      # List chat defaults for a specific channel
      lemon policy list telegram

      # Set a default for a route
      lemon policy set telegram --model claude-sonnet-4-20250514
      lemon policy set telegram --peer "-1001234567890" --model gpt-4o
      lemon policy set telegram --account bot1 --peer "-1001234567890" --thread "456" \\
        --model claude-opus-4-6 --thinking high

      # Get the effective defaults for a route
      lemon policy get telegram --peer "-1001234567890"

      # Clear a route's row
      lemon policy clear telegram --peer "-1001234567890"

      # Clear every row of a channel
      lemon policy clear telegram --all

  ## Options

    * `--account` - Account identifier (default `default` when `--peer` is given)
    * `--peer` - Peer/chat identifier (e.g., Discord channel ID, Telegram chat ID)
    * `--thread` - Thread/topic identifier (requires `--peer`)
    * `--model` - Model ID (e.g., "claude-sonnet-4-20250514", "gpt-4o")
    * `--thinking` - Thinking level (off, minimal, low, medium, high, xhigh, auto)
    * `--reason` - Reason for setting this default (stored with the row)
    * `--all` - For clear: clear every row of the channel
  """

  alias LemonCore.PolicyStore

  @thinking_levels ~w(off minimal low medium high xhigh auto)

  def run(args) do
    LemonCore.CLI.start!(:lemon_core)

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          account: :string,
          peer: :string,
          thread: :string,
          model: :string,
          thinking: :string,
          reason: :string,
          all: :boolean
        ],
        aliases: [a: :account, p: :peer, t: :thread, m: :model, r: :reason]
      )

    if invalid != [] do
      LemonCore.CLI.fail!("Invalid options: #{inspect(invalid)}", 2)
    end

    case rest do
      ["list" | channels] -> list_policies(channels)
      ["set", channel] -> set_policy(channel, opts)
      ["get", channel] -> get_policy(channel, opts)
      ["clear", channel] -> clear_policy(channel, opts)
      _ -> LemonCore.CLI.info(@moduledoc)
    end
  end

  @doc """
  The route `lemon policy` options name. `--peer` without `--account` names
  the `default` account, the account channel sessions use when none is
  configured; `--thread` requires `--peer`.
  """
  @spec route(String.t(), keyword()) :: {:ok, PolicyStore.chat_route()} | {:error, String.t()}
  def route(channel, opts) do
    peer = blank_to_nil(opts[:peer])
    thread = blank_to_nil(opts[:thread])
    account = blank_to_nil(opts[:account]) || if(peer, do: "default")
    route = {channel, account, peer, thread}

    cond do
      thread && is_nil(peer) -> {:error, "--thread requires --peer"}
      PolicyStore.chat_route?(route) -> {:ok, route}
      true -> {:error, "Invalid route: #{inspect(route)}"}
    end
  end

  defp list_policies(channels) do
    rows =
      case PolicyStore.fetch_chats() do
        {:ok, rows} -> rows
        {:error, _reason} -> LemonCore.CLI.fail!("The policy store is unavailable")
      end

    rows =
      rows
      |> Enum.filter(fn {{channel, _, _, _}, _row} -> channels == [] or channel in channels end)
      |> Enum.sort()

    if rows == [] do
      LemonCore.CLI.info("No model policies set.")
    else
      LemonCore.CLI.info("Model Policies:")
      LemonCore.CLI.info(String.duplicate("-", 80))

      Enum.each(rows, fn {route, row} ->
        LemonCore.CLI.info("  #{format_route(route)}")
        LemonCore.CLI.info("    Model:    #{row[:model] || "(inherited)"}")
        LemonCore.CLI.info("    Thinking: #{row[:thinking_level] || "(inherited)"}")
        if row[:reason], do: LemonCore.CLI.info("    Reason:   #{row[:reason]}")
        LemonCore.CLI.info("")
      end)
    end
  end

  defp set_policy(channel, opts) do
    route = route!(channel, opts)
    model = blank_to_nil(opts[:model])
    thinking = opts[:thinking] && normalize_thinking(opts[:thinking])

    cond do
      is_nil(model) and is_nil(opts[:thinking]) ->
        LemonCore.CLI.fail!("At least one of --model or --thinking must be specified", 2)

      opts[:thinking] && is_nil(thinking) ->
        LemonCore.CLI.fail!("--thinking must be one of: #{Enum.join(@thinking_levels, ", ")}", 2)

      true ->
        :ok
    end

    update = fn current ->
      (current || %{})
      |> put_present(:model, model)
      |> put_present(:thinking_level, thinking)
      |> put_present(:reason, opts[:reason])
      |> Map.merge(%{set_by: "lemon policy", updated_at_ms: System.system_time(:millisecond)})
    end

    case PolicyStore.update_chat(route, update) do
      {:ok, _row} -> LemonCore.CLI.info("Policy set for #{format_route(route)}")
      {:error, reason} -> LemonCore.CLI.fail!("Failed to set policy: #{inspect(reason)}")
    end
  end

  defp get_policy(channel, opts) do
    route = route!(channel, opts)

    case PolicyStore.resolve_chat(route) do
      {:ok, %{model: nil, thinking_level: nil}} ->
        LemonCore.CLI.info("No policy found for #{format_route(route)}")

      {:ok, defaults} ->
        LemonCore.CLI.info("Effective policy for #{format_route(route)}:")
        LemonCore.CLI.info("  Model:    #{defaults.model || "(none)"}")
        LemonCore.CLI.info("  Thinking: #{defaults.thinking_level || "(none)"}")

      {:error, _reason} ->
        LemonCore.CLI.fail!("The policy store is unavailable")
    end
  end

  defp clear_policy(channel, opts) do
    if opts[:all] do
      with {:ok, rows} <- PolicyStore.fetch_chats(),
           :ok <- clear_rows(for {{^channel, _, _, _} = route, _row} <- rows, do: route) do
        LemonCore.CLI.info("Cleared all policies for #{channel}")
      else
        {:error, reason} -> LemonCore.CLI.fail!("Failed to clear policies: #{inspect(reason)}")
      end
    else
      route = route!(channel, opts)

      case PolicyStore.delete_chat(route) do
        :ok -> LemonCore.CLI.info("Policy cleared for #{format_route(route)}")
        {:error, reason} -> LemonCore.CLI.fail!("Failed to clear policy: #{inspect(reason)}")
      end
    end
  end

  defp clear_rows(routes) do
    Enum.reduce_while(routes, :ok, fn route, :ok ->
      case PolicyStore.delete_chat(route) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp route!(channel, opts) do
    case route(channel, opts) do
      {:ok, route} -> route
      {:error, message} -> LemonCore.CLI.fail!(message, 2)
    end
  end

  defp format_route(route) do
    route |> Tuple.to_list() |> Enum.reject(&is_nil/1) |> Enum.join("/")
  end

  defp normalize_thinking(level) do
    normalized = level |> String.trim() |> String.downcase()
    if normalized in @thinking_levels, do: normalized
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
