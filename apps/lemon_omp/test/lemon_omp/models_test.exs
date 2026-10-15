defmodule LemonOmp.ModelsTest do
  use ExUnit.Case, async: false
  import LemonOmp.TestSupport

  setup do
    dir = tmp_dir!()
    executable = Path.join(dir, "omp")
    File.cp!(fake_omp(), executable)
    File.chmod!(executable, 0o755)
    put_app_env(:executable, executable)

    for key <- ~w(FAKE_OMP_MODELS_MODE FAKE_OMP_MODELS_COUNT LEMON_CATALOG_SECRET) do
      previous = System.get_env(key)
      System.delete_env(key)

      on_exit(fn ->
        if previous, do: System.put_env(key, previous), else: System.delete_env(key)
      end)
    end

    {:ok, dir: dir}
  end

  test "parses, sanitizes, sorts and filters catalog; caches invocation", %{dir: dir} do
    count = Path.join(dir, "count")
    System.put_env("FAKE_OMP_MODELS_COUNT", count)
    System.put_env("LEMON_CATALOG_SECRET", "must not leak")
    assert {:ok, models} = LemonOmp.models()
    assert length(models) == 30
    assert Enum.map(Enum.take(models, 3), & &1["selector"]) == ["free/a", "free/z", "cheap/c"]
    assert Enum.at(models, 1)["name"] == "Zed"
    assert hd(models)["contextWindow"] == 3000
    assert hd(models)["free"]
    refute Enum.at(models, 2)["free"]
    assert {:ok, [model]} = LemonOmp.models(query: "ALPHA", provider: "FREE", free_only: true)
    assert model["selector"] == "free/a"
    assert {:ok, free} = LemonOmp.models(free_only: true)
    assert length(free) == 2
    assert {:ok, capped} = LemonOmp.models(limit: 999)
    assert length(capped) == 200
    assert {:ok, [_]} = LemonOmp.models(limit: 0)
    assert File.read!(count) == "call\n"
  end

  for {mode, message} <- [
        {"malformed", "invalid catalog JSON"},
        {"fail", "status 7"},
        {"timeout", "timed out"}
      ] do
    test "catalog handles #{mode}" do
      System.put_env("FAKE_OMP_MODELS_MODE", unquote(mode))
      put_app_env(:models_timeout_ms, if(unquote(mode) == "timeout", do: 300, else: 2_000))
      assert {:error, {:catalog_failed, message}} = LemonOmp.models()
      assert message =~ unquote(message)
    end
  end

  test "missing executable is not installed" do
    put_app_env(:executable, "/nonexistent/omp")
    assert {:error, :not_installed} = LemonOmp.models()
  end

  test "tool describes models and fallback warning" do
    result =
      LemonOmp.Tools.Omp.execute(
        "catalog",
        %{"action" => "models", "free_only" => true},
        nil,
        nil,
        []
      )

    [content] = result.content
    assert content.text =~ "free/a — Alpha, ctx 3000, FREE"
    assert content.text =~ "catalog data"
    assert content.text =~ "404"
    assert content.text =~ "fall back"
    assert result.details["action"] == "models"
  end
end
