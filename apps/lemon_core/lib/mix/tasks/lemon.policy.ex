defmodule Mix.Tasks.Lemon.Policy do
  @moduledoc """
  Manage model policies for channels, accounts, peers, and threads.

  Model policies allow setting default models and thinking levels per route,
  with hierarchical precedence: session > thread > peer > account > channel > global.

  ## Usage

      # List all policies
      mix lemon.policy list

      # List policies for a specific channel
      mix lemon.policy list telegram

      # Set a policy for a route
      mix lemon.policy set telegram --model claude-sonnet-4-20250514
      mix lemon.policy set telegram --account default --peer "-1001234567890" --model gpt-4o
      mix lemon.policy set telegram --account default --peer "-1001234567890" --thread "456" \
        --model claude-opus-4-6 --thinking high

      # Get the effective policy for a route
      mix lemon.policy get telegram --account default --peer "-1001234567890"

      # Clear a policy
      mix lemon.policy clear telegram --account default --peer "-1001234567890"

      # Clear all policies for a channel
      mix lemon.policy clear telegram --all

  ## Options

    * `--account` - Account identifier (e.g., "default", "bot1")
    * `--peer` - Peer/chat identifier (e.g., Discord channel ID, Telegram chat ID)
    * `--thread` - Thread/topic identifier
    * `--model` - Model ID (e.g., "claude-sonnet-4-20250514", "gpt-4o")
    * `--thinking` - Thinking level (off, minimal, low, medium, high, xhigh)
    * `--reason` - Reason for setting this policy (stored in metadata)
    * `--all` - For clear command: clear all policies for the channel
  """

  use Mix.Task

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          account: :string,
          peer: :string,
          thread: :string,
          model: :string,
          thinking: :string,
          reason: :string,
          all: :boolean
        ],
        aliases: [
          a: :account,
          p: :peer,
          t: :thread,
          m: :model,
          r: :reason
        ]
      )

    case rest do
      ["list" | channels] ->
        list_policies(channels, opts)

      ["set", channel] ->
        set_policy(channel, opts)

      ["get", channel] ->
        get_policy(channel, opts)

      ["clear", channel] ->
        clear_policy(channel, opts)

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp list_policies(channels, _opts) do
    policies =
      if channels == [] do
        ModelPolicy.list()
      else
        channels
        |> Enum.flat_map(&ModelPolicy.list/1)
      end

    if policies == [] do
      Mix.shell().info("No model policies set.")
    else
      Mix.shell().info("Model Policies:")
      Mix.shell().info(String.duplicate("-", 80))

      Enum.each(policies, fn {route, policy} ->
        route_str = format_route(route)
        model_str = Map.get(policy, :model_id, "(inherited)")
        thinking_str = Map.get(policy, :thinking_level, "(inherited)")

        Mix.shell().info("  #{route_str}")
        Mix.shell().info("    Model:    #{model_str}")
        Mix.shell().info("    Thinking: #{thinking_str}")

        if policy[:metadata][:reason] do
          Mix.shell().info("    Reason:   #{policy.metadata.reason}")
        end

        Mix.shell().info("")
      end)
    end
  end

  defp set_policy(channel, opts) do
    model = opts[:model]
    thinking = opts[:thinking]

    if model == nil && thinking == nil do
      Mix.raise("At least one of --model or --thinking must be specified")
    end

    route = build_route(channel, opts)

    # If only thinking is set without a model, use a placeholder
    effective_model = model || "_thinking_only"

    policy =
      ModelPolicy.new_policy(effective_model,
        thinking_level: thinking,
        reason: opts[:reason],
        set_by: "mix lemon.policy"
      )

    case ModelPolicy.set(route, policy) do
      :ok ->
        Mix.shell().info("Policy set for #{format_route(route)}")

      {:error, reason} ->
        Mix.raise("Failed to set policy: #{inspect(reason)}")
    end
  end

  defp get_policy(channel, opts) do
    route = build_route(channel, opts)

    case ModelPolicy.resolve(route) do
      {:error, :not_found} ->
        Mix.shell().info("No policy found for #{format_route(route)}")

      {:ok, policy} ->
        Mix.shell().info("Effective policy for #{format_route(route)}:")
        Mix.shell().info("  Model:    #{policy[:model_id] || "(none)"}")
        Mix.shell().info("  Thinking: #{policy[:thinking_level] || "(none)"}")
    end
  end

  defp clear_policy(channel, opts) do
    if opts[:all] do
      ModelPolicy.clear_channel(channel)
      Mix.shell().info("Cleared all policies for #{channel}")
    else
      route = build_route(channel, opts)

      case ModelPolicy.clear(route) do
        :ok ->
          Mix.shell().info("Policy cleared for #{format_route(route)}")

        {:error, reason} ->
          Mix.raise("Failed to clear policy: #{inspect(reason)}")
      end
    end
  end

  defp build_route(channel, opts) do
    Route.new(channel, opts[:account], opts[:peer], opts[:thread])
  end

  defp format_route(%Route{} = route) do
    parts =
      [route.channel_id, route.account_id, route.peer_id, route.thread_id]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "/")
  end
end
