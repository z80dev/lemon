defmodule LemonControlPlane.Methods.SystemReloadTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SystemReload

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "system_reload_method_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "metadata" do
    test "name and scopes" do
      assert SystemReload.name() == "system.reload"
      assert SystemReload.scopes() == [:admin]
    end
  end

  describe "scope=module" do
    test "reloads a module and returns structured response" do
      {:ok, payload} =
        SystemReload.handle(%{"scope" => "module", "module" => "LemonCore.Clock"}, %{})

      assert payload["status"] in ["ok", "partial", "error"]
      assert payload["kind"] == "module"
      assert payload["target"] == "LemonCore.Clock"
      assert is_list(payload["reloaded"])
      assert is_list(payload["skipped"])
      assert is_list(payload["errors"])
      assert is_integer(payload["duration_ms"])
      assert is_list(payload["results"])
    end

    test "returns invalid_request when module param missing" do
      assert {:error, {:invalid_request, message}} =
               SystemReload.handle(%{"scope" => "module"}, %{})

      assert message =~ "module is required"
    end
  end

  describe "scope=app" do
    test "reloads an app and returns structured response" do
      {:ok, payload} = SystemReload.handle(%{"scope" => "app", "app" => "lemon_core"}, %{})

      assert payload["kind"] == "app"
      assert payload["target"] == ":lemon_core"
      assert payload["status"] in ["ok", "partial", "error"]
      assert is_list(payload["results"])
    end

    test "returns invalid_request when app param missing" do
      assert {:error, {:invalid_request, message}} =
               SystemReload.handle(%{"scope" => "app"}, %{})

      assert message =~ "app is required"
    end
  end

  describe "scope=extension" do
    test "reloads extension from path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "system_reload_extension_ok.ex")

      File.write!(
        path,
        """
        defmodule SystemReloadExtensionOk do
          @behaviour CodingAgent.Extensions.Extension
          def name, do: "system-reload-extension-ok"
          def version, do: "1.0.0"
          def tools(_cwd), do: []
        end
        """
      )

      {:ok, payload} = SystemReload.handle(%{"scope" => "extension", "path" => path}, %{})

      assert payload["kind"] == "extension"
      assert payload["target"] == inspect(path)
      assert payload["status"] in ["ok", "partial", "error"]
      assert is_list(payload["results"])

      _ = Lemon.Reload.soft_purge_module(SystemReloadExtensionOk)
    end

    test "returns invalid_request when path missing" do
      assert {:error, {:invalid_request, message}} =
               SystemReload.handle(%{"scope" => "extension"}, %{})

      assert message =~ "path is required"
    end
  end

  describe "scope=all" do
    test "delegates to unified reload workflow", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "system_reload_all_extension_ok.ex")

      File.write!(
        path,
        """
        defmodule SystemReloadAllExtensionOk do
          @behaviour CodingAgent.Extensions.Extension
          def name, do: "system-reload-all-extension-ok"
          def version, do: "1.0.0"
          def tools(_cwd), do: []
        end
        """
      )

      {:ok, payload} =
        SystemReload.handle(
          %{
            "scope" => "all",
            "apps" => ["lemon_core"],
            "extensions" => [path]
          },
          %{}
        )

      assert payload["kind"] == "system"
      assert payload["target"] == ":system"
      assert payload["status"] in ["ok", "partial", "error"]
      assert is_list(payload["results"])
      assert Enum.any?(payload["results"], &(&1["kind"] == "app"))
      assert Enum.any?(payload["results"], &(&1["kind"] == "extension"))

      _ = Lemon.Reload.soft_purge_module(SystemReloadAllExtensionOk)
    end
  end

  describe "validation and response shape" do
    test "rejects invalid scope" do
      assert {:error, {:invalid_request, message}} =
               SystemReload.handle(%{"scope" => "banana"}, %{})

      assert message =~ "Invalid scope"
    end

    test "default scope all when omitted" do
      {:ok, payload} = SystemReload.handle(%{"apps" => ["lemon_core"]}, %{})
      assert payload["kind"] == "system"
      assert Map.has_key?(payload, "status")
      assert Map.has_key?(payload, "results")
      assert Map.has_key?(payload, "reloaded")
      assert Map.has_key?(payload, "skipped")
      assert Map.has_key?(payload, "errors")
      assert Map.has_key?(payload, "duration_ms")
    end
  end
end
