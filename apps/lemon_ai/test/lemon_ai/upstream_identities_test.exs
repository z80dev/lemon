defmodule LemonAi.UpstreamIdentitiesTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/check_upstream_identities")
  @manifest_path "apps/lemon_ai/priv/upstream_identities.json"

  setup do
    root =
      Path.join(System.tmp_dir!(), "identity-pins-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    manifest = @root |> Path.join(@manifest_path) |> File.read!() |> Jason.decode!()

    for path <- [@manifest_path | Enum.map(manifest["code_pins"], & &1["path"])] |> Enum.uniq() do
      destination = Path.join(root, path)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(@root, path), destination)
    end

    {:ok, root: root, manifest: manifest}
  end

  test "the checked-in identities match their manifest without network access" do
    assert {output, 0} = check(@root)
    assert output =~ "Identity pins match (offline code)"
  end

  test "every pinned code constant and prompt rejects drift", %{root: root, manifest: manifest} do
    for pin <- manifest["code_pins"] do
      path = Path.join(root, pin["path"])
      original = File.read!(path)
      changed = String.replace(pin["text"], ~r/"[^"\n]*"/, "\"identity-drift\"", global: false)
      assert changed != pin["text"], "fixture must mutate #{pin["id"]}"
      File.write!(path, String.replace(original, pin["text"], changed, global: false))

      assert {output, 1} = check(root)
      assert output =~ pin["id"], output
      File.write!(path, original)
    end
  end

  test "removing or duplicating a pin cannot silently bypass the selector", %{
    root: root,
    manifest: manifest
  } do
    pin = Enum.find(manifest["code_pins"], &(&1["id"] == "claude-prefix"))
    path = Path.join(root, pin["path"])
    original = File.read!(path)
    File.write!(path, String.replace(original, pin["text"], "", global: false))
    assert {missing, 1} = check(root)
    assert missing =~ "expected 1 code matches"

    File.write!(path, original <> "\n" <> pin["text"] <> "\n")
    assert {duplicated, 1} = check(root)
    assert duplicated =~ "expected 1 code matches"
  end

  test "each repeated model-catalog header is covered", %{root: root, manifest: manifest} do
    pin = Enum.find(manifest["code_pins"], &(&1["id"] == "copilot-catalog-headers"))
    path = Path.join(root, pin["path"])
    original = File.read!(path)
    pieces = String.split(original, pin["text"])
    assert length(pieces) == pin["count"] + 1

    # Change the last copy, not just the first match.
    prefix = pieces |> Enum.drop(-1) |> Enum.join(pin["text"])
    changed = String.replace(pin["text"], "GitHubCopilotChat/0.35.0", "GitHubCopilotChat/9.9.9")
    File.write!(path, prefix <> changed <> List.last(pieces))
    assert {output, 1} = check(root)
    assert output =~ "copilot-catalog-headers: code drift"
  end

  test "missing code and malformed manifest fail closed", %{root: root, manifest: manifest} do
    pin = hd(manifest["code_pins"])
    File.rm!(Path.join(root, pin["path"]))
    assert {missing, 1} = check(root)
    assert missing =~ "cannot read pinned code"

    File.write!(Path.join(root, @manifest_path), "{}")
    assert {invalid, 1} = check(root)
    assert invalid =~ "invalid identity manifest"
  end

  test "a changed manifest hash or untracked source cannot approve a code edit", %{
    root: root,
    manifest: manifest
  } do
    [pin | rest] = manifest["code_pins"]

    for changed <- [
          Map.put(pin, "sha256", String.duplicate("0", 64)),
          Map.put(pin, "sources", ["missing"])
        ] do
      File.write!(
        Path.join(root, @manifest_path),
        Jason.encode!(%{manifest | "code_pins" => [changed | rest]})
      )

      assert {output, 1} = check(root)
      assert output =~ "invalid identity manifest"
    end
  end

  test "the manifest retains all imitated families and distinguishes operator identities", %{
    manifest: manifest
  } do
    ids = MapSet.new(manifest["code_pins"], & &1["id"])

    for id <- ~w(claude-prefix claude-client-id claude-oauth-betas claude-version claude-headers
                  copilot-client-id copilot-auth-headers copilot-anthropic-headers
                  copilot-completions-headers copilot-responses-headers copilot-catalog-headers
                  gemini-headers gemini-auth-headers gemini-auth-metadata gemini-body-identity
                  antigravity-headers antigravity-system-prompt antigravity-bridge-prompt
                  antigravity-request-type antigravity-fallback-project
                  codex-request-version codex-discovery-version codex-user-agent codex-originator
                  codex-discovery-originator codex-oauth-client-id kimi-client-id kimi-cli-version
                  kimi-request-fingerprint xai-client-id zcode-client-id zcode-redirect-identity) do
      assert MapSet.member?(ids, id), "untracked identity: #{id}"
    end

    assert Enum.any?(manifest["excluded"], &String.contains?(&1, "supplied by operators"))
    refute MapSet.member?(ids, "gemini-oauth-client-id")
    refute MapSet.member?(ids, "antigravity-oauth-client-id")
  end

  test "online logic fetches both immutable and latest npm artifacts" do
    result = online_probe("npm", "unchanged")
    assert result["errors"] == []
    assert Enum.any?(result["calls"], &String.ends_with?(&1, "/latest"))
    assert "https://fixture.invalid/pinned.tgz" in result["calls"]
    assert "https://fixture.invalid/latest.tgz" in result["calls"]
  end

  test "online logic rejects npm version, artifact, missing-file and transport drift" do
    for scenario <- ~w(version identity archive pinned missing unavailable) do
      result = online_probe("npm", scenario)
      assert result["errors"] != [], scenario
    end
  end

  test "GitHub watches current upstream content, not unrelated commit movement" do
    result = online_probe("github", "unchanged")
    assert result["errors"] == []
    assert Enum.any?(result["calls"], &String.ends_with?(&1, "/commits/HEAD"))
    assert Enum.any?(result["calls"], &String.contains?(&1, String.duplicate("a", 40)))
    assert Enum.any?(result["calls"], &String.contains?(&1, String.duplicate("b", 40)))
  end

  test "online logic rejects GitHub content, pinned-source and transport drift" do
    for scenario <- ~w(identity pinned missing unavailable) do
      result = online_probe("github", scenario)
      assert result["errors"] != [], scenario
    end
  end

  defp check(root) do
    System.cmd("python3", [@script, "--offline", "--root", root], stderr_to_stdout: true)
  end

  # Exercise the production network-check logic with in-memory responses. These
  # regressions never contact npm/GitHub, require credentials, or execute packages.
  @online_probe ~S"""
  import gzip, hashlib, io, json, runpy, sys, tarfile
  checker = runpy.run_path(sys.argv[1])
  kind, scenario = sys.argv[2:]
  original = b"reviewed-identity"
  pinned = b"changed-identity" if scenario == "pinned" else original
  latest = b"changed-identity" if scenario == "identity" else original
  digest = lambda data: hashlib.sha256(data).hexdigest()
  responses = {}
  calls = []

  def archive(body, missing=False):
      buffer = io.BytesIO()
      with tarfile.open(fileobj=buffer, mode="w") as tar:
          info = tarfile.TarInfo("package/missing.txt" if missing else "package/identity.txt")
          info.size = len(body)
          tar.addfile(info, io.BytesIO(body))
      return gzip.compress(buffer.getvalue(), mtime=0)

  if kind == "npm":
      pinned_archive = archive(pinned)
      source = {"id": "fixture", "kind": "npm", "package": "@fixture/client", "version": "1.0.0",
                "archive_sha256": "0" * 64 if scenario == "archive" else digest(pinned_archive),
                "files": [{"path": "package/identity.txt", "sha256": digest(original)}]}
      registry = "https://registry.npmjs.org/@fixture/client/"
      for tag, url, version in [("1.0.0", "pinned", "1.0.0"),
                                 ("latest", "latest", "2.0.0" if scenario == "version" else "1.0.0")]:
          responses[registry + tag] = json.dumps({"name": "@fixture/client", "version": version,
              "dist": {"tarball": "https://fixture.invalid/" + url + ".tgz"}}).encode()
      responses["https://fixture.invalid/pinned.tgz"] = pinned_archive
      responses["https://fixture.invalid/latest.tgz"] = archive(latest, scenario == "missing")
  else:
      source = {"id": "fixture", "kind": "github", "repository": "fixture/client", "revision": "a" * 40,
                "files": [{"path": "identity.txt", "sha256": digest(original)}]}
      responses["https://api.github.com/repos/fixture/client/commits/HEAD"] = json.dumps({"sha": "b" * 40}).encode()
      responses["https://raw.githubusercontent.com/fixture/client/" + "a" * 40 + "/identity.txt"] = pinned
      if scenario != "missing":
          responses["https://raw.githubusercontent.com/fixture/client/" + "b" * 40 + "/identity.txt"] = latest

  def get(url):
      calls.append(url)
      if scenario == "unavailable" or url not in responses:
          raise OSError("upstream unavailable")
      return responses[url]

  errors = checker["check_upstreams"]({"sources": [source]}, get)
  print(json.dumps({"errors": errors, "calls": calls}))
  """

  defp online_probe(kind, scenario) do
    {output, 0} =
      System.cmd("python3", ["-c", @online_probe, @script, kind, scenario],
        stderr_to_stdout: true
      )

    Jason.decode!(output)
  end
end
