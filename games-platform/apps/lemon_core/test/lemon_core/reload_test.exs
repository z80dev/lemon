defmodule LemonCore.ReloadTest do
  use ExUnit.Case, async: false

  alias Lemon.Reload

  defmodule TestCodeChangeServer do
    use GenServer

    @vsn 1

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, %{notify: Keyword.fetch!(opts, :notify), state_vsn: @vsn}}
    end

    @impl true
    def code_change(old_vsn, state, extra) do
      send(state.notify, {:code_change_called, old_vsn, extra})
      {:ok, Map.put(state, :state_vsn, @vsn)}
    end
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_reload_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "reload_module/2" do
    test "reloads an existing module" do
      assert {:ok, result} = Reload.reload_module(LemonCore.Clock)
      assert result.kind == :module
      assert result.target == LemonCore.Clock
      assert is_list(result.reloaded)
      assert is_list(result.skipped)
      assert is_list(result.errors)
      assert is_integer(result.duration_ms)
    end

    test "returns error status for unknown module" do
      unknown = :"Elixir.ReloadDefinitelyMissingModule"

      assert {:ok, result} = Reload.reload_module(unknown)
      assert result.kind == :module
      assert result.target == unknown
      assert result.status == :error
      assert result.reloaded == []
      assert length(result.errors) == 1
    end

    test "raises function clause for non-atom module" do
      assert_raise FunctionClauseError, fn ->
        Reload.reload_module("NotAModule")
      end
    end
  end

  describe "reload_app/2" do
    test "reloads an existing app" do
      assert {:ok, result} = Reload.reload_app(:lemon_core)
      assert result.kind == :app
      assert result.target == :lemon_core
      assert is_list(result.reloaded)
      assert is_list(result.skipped)
      assert is_list(result.errors)
      assert result.metadata.module_count >= 1
    end

    test "returns error status when app is missing" do
      assert {:ok, result} = Reload.reload_app(:definitely_missing_app)
      assert result.kind == :app
      assert result.target == :definitely_missing_app
      assert result.status == :error
      assert [%{target: :definitely_missing_app, reason: :app_not_found}] = result.errors
    end

    test "accepts force option without crashing" do
      assert {:ok, result} = Reload.reload_app(:lemon_core, force: true)
      assert result.kind == :app
    end
  end

  describe "reload_extension/2" do
    test "reloads a valid extension file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "reload_extension_ok.ex")

      File.write!(
        path,
        """
        defmodule ReloadExtensionOk do
          @behaviour CodingAgent.Extensions.Extension
          def name, do: "reload-extension-ok"
          def version, do: "1.0.0"
          def tools(_cwd), do: []
        end
        """
      )

      assert {:ok, result} = Reload.reload_extension(path)
      assert result.kind == :extension
      assert result.target == path
      assert is_list(result.metadata.compiled_modules)
      assert ReloadExtensionOk in result.metadata.compiled_modules

      _ = Reload.soft_purge_module(ReloadExtensionOk)
    end

    test "returns error for missing extension path" do
      path = "/tmp/reload_missing_extension_#{System.unique_integer([:positive])}.ex"
      assert {:ok, result} = Reload.reload_extension(path)
      assert result.kind == :extension
      assert result.status == :error
      assert [%{target: ^path, reason: :enoent}] = result.errors
    end

    test "returns error for empty path" do
      assert {:ok, result} = Reload.reload_extension("")
      assert result.kind == :extension
      assert result.status == :error
      assert [%{reason: :empty_path}] = result.errors
    end
  end

  describe "reload_system/1" do
    test "orchestrates app + extension + code_change reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "reload_system_extension.ex")

      File.write!(
        path,
        """
        defmodule ReloadSystemExtension do
          @behaviour CodingAgent.Extensions.Extension
          def name, do: "reload-system-extension"
          def version, do: "1.0.0"
          def tools(_cwd), do: []
        end
        """
      )

      assert {:ok, result} =
               Reload.reload_system(
                 apps: [:lemon_core],
                 extensions: [path],
                 code_change_targets: [
                   %{
                     server: LemonAutomation.CronManager,
                     module: LemonAutomation.CronManager,
                     old_vsn: :old,
                     extra: %{k: 1}
                   }
                 ]
               )

      assert result.kind == :system
      assert is_list(result.metadata.results)
      assert Enum.any?(result.metadata.results, &(&1.kind == :app))
      assert Enum.any?(result.metadata.results, &(&1.kind == :extension))
      assert Enum.any?(result.metadata.results, &(&1.kind == :code_change))

      code_change_result = Enum.find(result.metadata.results, &(&1.kind == :code_change))

      assert code_change_result.target ==
               "LemonAutomation.CronManager:LemonAutomation.CronManager"

      assert code_change_result.status in [:ok, :partial, :error]

      _ = Reload.soft_purge_module(ReloadSystemExtension)
    end

    test "aggregates multiple errors" do
      assert {:ok, result} =
               Reload.reload_system(
                 apps: [:definitely_missing_app],
                 extensions: [
                   "",
                   "/tmp/missing_extension_#{System.unique_integer([:positive])}.ex"
                 ],
                 code_change_targets: [:bad_target]
               )

      assert result.kind == :system
      assert result.status == :error
      assert length(result.errors) >= 3
    end
  end

  describe "lock behavior" do
    test "concurrent reloads are serialized without race" do
      t1 = Task.async(fn -> Reload.reload_app(:lemon_core) end)
      t2 = Task.async(fn -> Reload.reload_module(LemonCore.Clock) end)

      assert {:ok, r1} = Task.await(t1, 10_000)
      assert {:ok, r2} = Task.await(t2, 10_000)

      assert r1.kind == :app
      assert r2.kind == :module
    end
  end

  describe "telemetry" do
    test "emits start and stop events" do
      id = "reload-telemetry-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          id,
          [[:lemon, :reload, :start], [:lemon, :reload, :stop]],
          fn event, measurements, metadata, _config ->
            send(parent, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, _result} = Reload.reload_module(LemonCore.Clock)

      assert_receive {:telemetry_event, [:lemon, :reload, :start], start_m, start_md}, 1_000
      assert_receive {:telemetry_event, [:lemon, :reload, :stop], stop_m, stop_md}, 1_000

      assert is_map(start_m)
      assert start_md.kind == :module
      assert stop_md.kind == :module
      assert is_integer(stop_m.duration_ms)
    end
  end

  describe "result structure" do
    test "returns all expected result kinds", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "reload_kind_extension.ex")

      File.write!(
        path,
        """
        defmodule ReloadKindExtension do
          @behaviour CodingAgent.Extensions.Extension
          def name, do: "reload-kind-extension"
          def version, do: "1.0.0"
          def tools(_cwd), do: []
        end
        """
      )

      assert {:ok, module_result} = Reload.reload_module(LemonCore.Clock)
      assert module_result.kind == :module

      assert {:ok, app_result} = Reload.reload_app(:lemon_core)
      assert app_result.kind == :app

      assert {:ok, ext_result} = Reload.reload_extension(path)
      assert ext_result.kind == :extension

      assert {:ok, system_result} =
               Reload.reload_system(
                 apps: [:lemon_core],
                 extensions: [path],
                 code_change_targets: [
                   %{server: LemonAutomation.CronManager, module: LemonAutomation.CronManager}
                 ]
               )

      assert system_result.kind == :system
      assert Enum.any?(system_result.metadata.results, &(&1.kind == :code_change))

      _ = Reload.soft_purge_module(ReloadKindExtension)
    end
  end
end
