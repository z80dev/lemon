defmodule LemonAutomation.RunnerConfig do
  @moduledoc false

  def config(key, defaults, opts \\ []) do
    app_cfg =
      :lemon_automation
      |> Application.get_env(key, [])
      |> normalize_config(defaults)

    Keyword.merge(defaults, Keyword.merge(app_cfg, opts))
  end

  def enabled?(cfg), do: Keyword.get(cfg, :enabled, true) == true

  def active_sessions?(opts \\ []) do
    sessions_fun = Keyword.get(opts, :active_sessions_fun)

    sessions =
      if is_function(sessions_fun, 0) do
        sessions_fun.()
      else
        router_mod = Keyword.get(opts, :active_sessions_mod, LemonRouter.Router)
        router_mod.list_active_sessions()
      end

    match?([_ | _], sessions) or match?({:error, _reason}, sessions)
  rescue
    _ -> true
  catch
    _kind, _reason -> true
  end

  def idle_for_seconds(opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, LemonCore.Clock.now_ms())
    last_busy_at_ms = Keyword.get(opts, :last_busy_at_ms, now_ms)
    max(0, div(now_ms - last_busy_at_ms, 1000))
  end

  def positive_integer(cfg, key, default) do
    case Keyword.get(cfg, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_config(config, defaults) when is_map(config) do
    string_keys = Map.new(defaults, fn {key, _value} -> {Atom.to_string(key), key} end)

    Enum.flat_map(config, fn {key, value} ->
      case normalize_key(key, string_keys) do
        key when is_atom(key) -> [{key, value}]
        _ -> []
      end
    end)
  end

  defp normalize_config(config, _defaults) when is_list(config), do: config
  defp normalize_config(_config, _defaults), do: []

  defp normalize_key(key, _string_keys) when is_atom(key), do: key
  defp normalize_key(key, string_keys) when is_binary(key), do: Map.get(string_keys, key, key)
end
