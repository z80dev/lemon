defmodule LemonAutomation.Blueprint.CatalogTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.Blueprint.Catalog

  @tag :tmp_dir
  test "derives the canonical catalog and returns content-free bundle projections", %{tmp_dir: root} do
    opts = catalog_opts(root)
    catalog = Catalog.root(opts)
    bundle = Path.join(catalog, "daily-note")

    File.mkdir_p!(catalog)

    copy_example!(bundle)

    assert catalog == Path.join([root, "state", "bundles"])
    assert {:ok, %{"bundles" => [%{"id" => "daily-note"}]}} = Catalog.list(opts)
    assert {:ok, %{"id" => "daily-note"} = inspected} = Catalog.inspect("daily-note", opts)
    assert {:ok, %{"validation" => %{"valid" => true}}} = Catalog.validate("daily-note", opts)

    wire = Jason.encode!(inspected)
    refute wire =~ root
    refute wire =~ "Use the daily-note skill"
    refute wire =~ "Summarize completed work from the current conversation"
  end

  @tag :tmp_dir
  test "rejects forged IDs, symlinks, and manifest identity mismatches", %{tmp_dir: root} do
    opts = catalog_opts(root)
    catalog = Catalog.root(opts)
    File.mkdir_p!(catalog)

    assert {:error, {:invalid_bundle_id, _}} = Catalog.inspect("../escape", opts)
    assert {:error, {:invalid_bundle_id, _}} = Catalog.inspect("Daily-Note", opts)

    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(catalog, "linked"))
    assert {:error, {:symlink_not_allowed, _}} = Catalog.inspect("linked", opts)

    mismatched = Path.join(catalog, "mismatched")
    copy_example!(mismatched)

    manifest_path = Path.join(mismatched, "bundle.json")

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("id", "different")
      |> Map.put("name", "Private metadata")
      |> Map.put("description", "Private metadata")

    File.write!(manifest_path, Jason.encode!(manifest))

    assert {:error, {:bundle_id_mismatch, message}} = Catalog.inspect("mismatched", opts)
    refute message =~ "Private metadata"
    refute message =~ root
  end

  defp catalog_opts(root) do
    state = Path.join(root, "state")

    [
      profile_opts: [
        home_state_dir: state,
        config_path: Path.join(state, "config.toml")
      ]
    ]
  end

  defp copy_example!(destination) do
    source =
      Path.expand(
        "../../../../../examples/skill-automation-bundles/daily-note",
        __DIR__
      )

    assert {:ok, _copied} = File.cp_r(source, destination)
  end
end
