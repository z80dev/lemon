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
      mix lemon.policy set telegram --account default --peer "-1001234567890" --thread "456" \\
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
    * `--thinking` - Thinking level (minimal, low, medium, high, xhigh)
    * `--reason` - Reason for setting this policy (stored in metadata)
    * `--all` - For clear command: clear all policies for the channel

  ## Examples

      # Set cheaper model for a specific Discord channel
      mix lemon.policy set discord --account bot1 --peer "123456789012345678" \\
        --model "gpt-4o-mini" --reason "Cost optimization for general chat"

      # Set high-reasoning model for a specific thread
      mix lemon.policy set telegram --account default --peer "-1001234567890" \\
        --thread "456" --model "claude-opus-4-6" --thinking high \\
        --reason "Deep reasoning required for this topic"
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
      case channels do
        [] -> ModelPolicy.list()
        [channel | _] -> ModelPolicy.list(channel)
      end

    if Enum.empty?(policies) do
      Mix.shell().info("No policies configured.")
    else
      Mix.shell().info("Model Policies")
      Mix.shell().info("==============")
      Mix.shell().info("")

      policies
      |> Enum.sort_by(fn {route, _} ->
        {route.channel_id, route.account_id || "", route.peer_id || "", route.thread_id || ""}
      end)
      |> Enum.each(fn {route, policy} ->
        route_str = format_route(route)
        model_str = policy.model_id
        thinking_str = if policy.thinking_level, do: " (#{policy.thinking_level})", else: ""

        Mix.shell().info("  #{route_str}")
        Mix.shell().info("    Model: #{model_str}#{thinking_str}")

        if policy.metadata.reason do
          Mix.shell().info("    Reason: #{policy.metadata.reason}")
        end

        Mix.shell().info("")
      end)

      Mix.shell().info("Total: #{length(policies)} policy/policies")
    end
  end

  defp set_policy(channel, opts) do
    model = opts[:model]

    if is_nil(model) or model == "" do
      Mix.raise("--model is required")
    end

    route =
      Route.new(
        channel,
        opts[:account],
        opts[:peer],
        opts[:thread]
      )

    thinking_level = parse_thinking_level(opts[:thinking])

    policy_opts = [
      set_by: "mix lemon.policy",
      reason: opts[:reason]
    ]

    policy_opts =
      if thinking_level do
        Keyword.put(policy_opts, :thinking_level, thinking_level)
      else
        policy_opts
      end

    policy = ModelPolicy.new_policy(model, policy_opts)

    case ModelPolicy.set(route, policy) do
      :ok ->
        route_str = format_route(route)
        thinking_str = if thinking_level, do: " with #{thinking_level} thinking", else: ""

        Mix.shell().info([:green, "✓ Policy set", :reset])
        Mix.shell().info("  Route: #{route_str}")
        Mix.shell().info("  Model: #{model}#{thinking_str}")

      {:error, reason} ->
        Mix.raise("Failed to set policy: #{inspect(reason)}")
    end
  end

  defp get_policy(channel, opts) do
    route =
      Route.new(
        channel,
        opts[:account],
        opts[:peer],
        opts[:thread]
      )

    route_str = format_route(route)

    case ModelPolicy.resolve(route) do
      {:ok, policy} ->
        exact_policy = ModelPolicy.get(route)

        Mix.shell().info("Effective Policy")
        Mix.shell().info("================")
        Mix.shell().info("")
        Mix.shell().info("  Route: #{route_str}")
        Mix.shell().info("  Model: #{policy.model_id}")

        if policy.thinking_level do
          Mix.shell().info("  Thinking: #{policy.thinking_level}")
        end

        if exact_policy do
          Mix.shell().info("")
          Mix.shell().info("  (Exact match for this route)")
        else
          Mix.shell().info("")
          Mix.shell().info("  (Inherited from less specific route)")
        end

        if policy.metadata.reason do
          Mix.shell().info("  Reason: #{policy.metadata.reason}")
        end

        if policy.metadata.set_by do
          Mix.shell().info("  Set by: #{policy.metadata.set_by}")
        end

        if policy.metadata.set_at_ms do
          set_at = DateTime.from_unix!(policy.metadata.set_at_ms, :millisecond)
          Mix.shell().info("  Set at: #{DateTime.to_iso8601(set_at)}")
        end

      {:error, :not_found} ->
        Mix.shell().info("No policy configured for: #{route_str}")
        Mix.shell().info("")
        Mix.shell().info("The global default model will be used.")
    end
  end

  defp clear_policy(channel, opts) do
    if opts[:all] do
      case ModelPolicy.clear_channel(channel) do
        :ok ->
          Mix.shell().info([:green, "✓ All policies cleared for channel: #{channel}", :reset])
      end
    else
      route =
        Route.new(
          channel,
          opts[:account],
          opts[:peer],
          opts[:thread]
        )

      case ModelPolicy.clear(route) do
        :ok ->
          route_str = format_route(route)
          Mix.shell().info([:green, "✓ Policy cleared for: #{route_str}", :reset])

        {:error, reason} ->
          Mix.raise("Failed to clear policy: #{inspect(reason)}")
      end
    end
  end

  defp format_route(%Route{} = route) do
    parts = [route.channel_id]

    parts =
      if route.account_id do
        parts ++ [route.account_id]
      else
        parts ++ ["*"]
      end

    parts =
      if route.peer_id do
        parts ++ [route.peer_id]
      else
        parts ++ ["*"]
      end

    parts =
      if route.thread_id do
        parts ++ [route.thread_id]
      else
        if route.peer_id do
          parts ++ ["*"]
        else
          parts
        end
      end

    Enum.join(parts, "/")
  end

  defp parse_thinking_level(nil), do: nil

  defp parse_thinking_level(level) when is_binary(level) do
    case String.downcase(level) do
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
      _ -> Mix.raise("Invalid thinking level: #{level}. Use: minimal, low, medium, high, xhigh")
    end
  end
end
