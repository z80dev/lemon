defmodule LemonChannels.ModelPolicy.CLI do
  @moduledoc """
  Manage model policies for channels, accounts, peers, and threads.

  Model policies allow setting default models and thinking levels per route,
  with hierarchical precedence: session > thread > peer > account > channel > global.

  ## Usage

      # List all policies
      lemon policy list

      # List policies for a specific channel
      lemon policy list telegram

      # Set a policy for a route
      lemon policy set telegram --model claude-sonnet-4-20250514
      lemon policy set telegram --account default --peer "-1001234567890" --model gpt-4o
      lemon policy set telegram --account default --peer "-1001234567890" --thread "456" \
        --model claude-opus-4-6 --thinking high

      # Get the effective policy for a route
      lemon policy get telegram --account default --peer "-1001234567890"

      # Clear a policy
      lemon policy clear telegram --account default --peer "-1001234567890"

      # Clear all policies for a channel
      lemon policy clear telegram --all

  ## Options

    * `--account` - Account identifier (e.g., "default", "bot1")
    * `--peer` - Peer/chat identifier (e.g., Discord channel ID, Telegram chat ID)
    * `--thread` - Thread/topic identifier
    * `--model` - Model ID (e.g., "claude-sonnet-4-20250514", "gpt-4o")
    * `--thinking` - Thinking level (off, minimal, low, medium, high, xhigh, auto)
    * `--reason` - Reason for setting this policy (stored in metadata)
    * `--all` - For clear command: clear all policies for the channel
  """

  alias LemonChannels.ModelPolicy
  alias LemonChannels.ModelPolicy.Route

  @placeholder_model_id "_thinking_only"
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
        aliases: [
          a: :account,
          p: :peer,
          t: :thread,
          m: :model,
          r: :reason
        ]
      )

    if invalid != [] do
      LemonCore.CLI.fail!("Invalid options: #{inspect(invalid)}", 2)
    end

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
        LemonCore.CLI.info(@moduledoc)
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
      LemonCore.CLI.info("No model policies set.")
    else
      LemonCore.CLI.info("Model Policies:")
      LemonCore.CLI.info(String.duplicate("-", 80))

      Enum.each(policies, fn {route, policy} ->
        route_str = format_route(route)
        model_str = display_model_id(Map.get(policy, :model_id))
        thinking_str = display_thinking_level(Map.get(policy, :thinking_level), "(inherited)")

        LemonCore.CLI.info("  #{route_str}")
        LemonCore.CLI.info("    Model:    #{model_str}")
        LemonCore.CLI.info("    Thinking: #{thinking_str}")

        if policy[:metadata][:reason] do
          LemonCore.CLI.info("    Reason:   #{policy.metadata.reason}")
        end

        LemonCore.CLI.info("")
      end)
    end
  end

  defp set_policy(channel, opts) do
    model = opts[:model]
    thinking = opts[:thinking]

    if model == nil && thinking == nil do
      LemonCore.CLI.fail!("At least one of --model or --thinking must be specified", 2)
    end

    route = build_route(channel, opts)
    existing = ModelPolicy.get(route)

    effective_model =
      cond do
        real_model_id?(model) ->
          model

        real_model_id?(existing && existing[:model_id]) ->
          existing[:model_id]

        true ->
          @placeholder_model_id
      end

    effective_thinking =
      cond do
        normalized_thinking_level(thinking) != nil -> thinking
        true -> existing && existing[:thinking_level]
      end

    policy =
      ModelPolicy.new_policy(effective_model,
        thinking_level: effective_thinking,
        reason: opts[:reason],
        set_by: "lemon policy"
      )

    case ModelPolicy.set(route, policy) do
      :ok ->
        LemonCore.CLI.info("Policy set for #{format_route(route)}")

      {:error, reason} ->
        LemonCore.CLI.fail!("Failed to set policy: #{inspect(reason)}")
    end
  end

  defp get_policy(channel, opts) do
    route = build_route(channel, opts)

    case ModelPolicy.resolve(route) do
      {:error, :not_found} ->
        LemonCore.CLI.info("No policy found for #{format_route(route)}")

      {:ok, _policy} ->
        LemonCore.CLI.info("Effective policy for #{format_route(route)}:")
        LemonCore.CLI.info("  Model:    #{resolve_effective_model(route) || "(none)"}")

        LemonCore.CLI.info(
          "  Thinking: #{display_thinking_level(ModelPolicy.resolve_thinking_level(route), "(none)")}"
        )
    end
  end

  defp clear_policy(channel, opts) do
    if opts[:all] do
      ModelPolicy.clear_channel(channel)
      LemonCore.CLI.info("Cleared all policies for #{channel}")
    else
      route = build_route(channel, opts)

      case ModelPolicy.clear(route) do
        :ok ->
          LemonCore.CLI.info("Policy cleared for #{format_route(route)}")

        {:error, reason} ->
          LemonCore.CLI.fail!("Failed to clear policy: #{inspect(reason)}")
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

  defp resolve_effective_model(%Route{} = route) do
    route
    |> Route.precedence_keys()
    |> Enum.find_value(fn key ->
      key
      |> Route.from_key()
      |> ModelPolicy.get()
      |> then(fn
        %{model_id: model_id} when is_binary(model_id) ->
          if real_model_id?(model_id), do: model_id, else: nil

        _ ->
          nil
      end)
    end)
  end

  defp display_model_id(model_id) when is_binary(model_id) do
    if real_model_id?(model_id), do: model_id, else: "(none)"
  end

  defp display_model_id(_model_id), do: "(none)"

  defp display_thinking_level(level, _fallback) when is_atom(level) do
    Atom.to_string(level)
  end

  defp display_thinking_level(level, _fallback) when is_binary(level) do
    level
  end

  defp display_thinking_level(_level, fallback), do: fallback

  defp normalized_thinking_level(level) when is_atom(level) do
    level
    |> Atom.to_string()
    |> normalized_thinking_level()
  end

  defp normalized_thinking_level(level) when is_binary(level) do
    normalized = String.downcase(String.trim(level))
    if normalized in @thinking_levels, do: normalized, else: nil
  end

  defp normalized_thinking_level(_level), do: nil

  defp real_model_id?(model_id) when is_binary(model_id) do
    normalized = String.trim(model_id)
    normalized != "" and normalized != @placeholder_model_id
  end

  defp real_model_id?(_model_id), do: false
end
