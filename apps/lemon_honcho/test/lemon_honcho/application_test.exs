defmodule LemonHoncho.ApplicationTest do
  use ExUnit.Case, async: false

  alias LemonAgent.{ContextRegistry, ToolRegistry}
  alias LemonMemory.Providers

  @tools [
    honcho_reasoning: LemonHoncho.Tools.Reasoning,
    honcho_search: LemonHoncho.Tools.Search,
    honcho_context: LemonHoncho.Tools.Context,
    honcho_profile: LemonHoncho.Tools.Profile,
    honcho_conclude: LemonHoncho.Tools.Conclude
  ]
  @env_vars ~w(HONCHO_API_KEY HONCHO_BASE_URL LEMON_HONCHO_ENABLED)
  @app_keys [:enabled, :api_key, :base_url, :start_session_manager, :client]

  setup do
    running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :lemon_honcho))
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})

    registries =
      Map.new([ToolRegistry, ContextRegistry], fn registry ->
        key = {registry, :registered}
        {key, :persistent_term.get(key, :absent)}
      end)

    provider =
      if Process.whereis(Providers) do
        Enum.find(GenServer.call(Providers, :provider_specs), &(&1.id == "honcho"))
      end

    Application.stop(:lemon_honcho)
    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:lemon_honcho, &1))
    Application.put_env(:lemon_honcho, :enabled, true)
    Application.put_env(:lemon_honcho, :start_session_manager, false)
    Application.put_env(:lemon_honcho, :client, LemonHoncho.Client.Tripwire)
    Enum.each(@tools, fn {name, _module} -> ToolRegistry.unregister(name) end)
    ContextRegistry.unregister(:honcho)

    on_exit(fn ->
      Application.stop(:lemon_honcho)

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(saved_app, fn
        {key, :error} -> Application.delete_env(:lemon_honcho, key)
        {key, {:ok, value}} -> Application.put_env(:lemon_honcho, key, value)
      end)

      if running?, do: Application.ensure_all_started(:lemon_honcho)

      Enum.each(registries, fn
        {key, :absent} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)

      if Process.whereis(Providers) do
        Providers.unregister_provider("honcho")
        if provider, do: Providers.register_provider(provider)
      end
    end)

    :ok
  end

  test "enabled without credentials registers no Honcho tools" do
    assert {:ok, _} = Application.ensure_all_started(:lemon_honcho)
    assert honcho_tools() == []
    refute Keyword.has_key?(ContextRegistry.all(), :honcho)
  end

  test "disabled with credentials registers no Honcho tools" do
    Application.put_env(:lemon_honcho, :enabled, false)
    Application.put_env(:lemon_honcho, :api_key, "test-key")

    assert {:ok, _} = Application.ensure_all_started(:lemon_honcho)
    assert honcho_tools() == []
    refute Keyword.has_key?(ContextRegistry.all(), :honcho)
  end

  for {setting, value} <- [api_key: "test-key", base_url: "http://honcho.invalid"] do
    test "enabled with #{setting} registers all five tools" do
      Application.put_env(:lemon_honcho, unquote(setting), unquote(value))

      assert {:ok, _} = Application.ensure_all_started(:lemon_honcho)
      assert honcho_tools() == @tools
      assert Keyword.get(ContextRegistry.all(), :honcho) == LemonHoncho.ContextContributor
    end
  end

  defp honcho_tools do
    Enum.filter(ToolRegistry.all(), fn {name, _module} ->
      String.starts_with?(Atom.to_string(name), "honcho_")
    end)
  end
end
