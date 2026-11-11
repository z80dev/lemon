defmodule LemonCli.UninstallCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.UninstallCommand

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join([home, ".lemon", "versions"]))
    File.mkdir_p!(Path.join([home, ".lemon", "bin"]))

    File.write!(Path.join(home, ".zshrc"), """
    export EDITOR=vim

    # added by the lemon installer
    export PATH="$HOME/.lemon/bin:$PATH"
    """)

    opts = [home: home, cli_launcher: :release, env: %{}, os: :linux]
    {:ok, home: home, opts: opts}
  end

  defp run(args, opts \\ []) do
    result = %{code: nil}

    output =
      capture_io(fn ->
        send(self(), {:code, UninstallCommand.run(args, opts)})
      end)

    receive do
      {:code, code} -> {output, Map.put(result, :code, code)}
    end
  end

  test "usage errors exit 2 without previewing" do
    {output, %{code: 2}} = run(["--bogus"])
    assert output == ""
  end

  test "--help exits 0 and documents preview and confirm" do
    {output, %{code: 0}} = run(["--help"])
    assert output =~ "lemon uninstall"
    assert output =~ "--purge"
    assert output =~ "--confirm DIGEST"
  end

  test "the default run previews and prints a confirmation digest", %{home: home, opts: opts} do
    {output, %{code: 0}} = run([], opts)

    assert output =~ "Lemon uninstall preview"
    assert output =~ Path.join([home, ".lemon", "versions"])
    assert output =~ "# added by the lemon installer"
    assert output =~ "Purge data (~/.lemon): no"
    assert [_, digest] = Regex.run(~r/Confirmation digest: ([0-9a-f]{64})/, output)
    assert output =~ "lemon uninstall --confirm #{digest}"

    # A preview changes nothing.
    assert File.exists?(Path.join([home, ".lemon", "versions"]))
    assert File.read!(Path.join(home, ".zshrc")) =~ "added by the lemon installer"
  end

  test "--purge preview names the data directory and a different digest", %{opts: opts} do
    {plain, %{code: 0}} = run([], opts)
    {purge, %{code: 0}} = run(["--purge"], opts)

    assert purge =~ "Purge data (~/.lemon): yes"
    assert purge =~ "lemon uninstall --purge --confirm"

    [_, plain_digest] = Regex.run(~r/Confirmation digest: ([0-9a-f]{64})/, plain)
    [_, purge_digest] = Regex.run(~r/Confirmation digest: ([0-9a-f]{64})/, purge)
    refute plain_digest == purge_digest
  end

  test "--json preview emits the candidate set and digest", %{home: home, opts: opts} do
    {output, %{code: 0}} = run(["--json"], opts)
    payload = Jason.decode!(output)

    assert payload["ok"] == true
    assert payload["source"] == false
    assert is_list(payload["units"])
    assert Path.join([home, ".lemon", "versions"]) in payload["programs"]
    assert payload["purge"] == false
    assert payload["purge_paths"] == []
    assert payload["confirmation_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    assert [%{"file" => _, "line" => _}] = payload["rc_lines"]
  end

  test "a wrong digest fails with exit 1 and changes nothing", %{home: home, opts: opts} do
    output =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 send(
                   self(),
                   {:code, UninstallCommand.run(["--confirm", String.duplicate("a", 64)], opts)}
                 )
               end) == ""
      end)

    assert_received {:code, 1}
    assert output =~ "confirmation digest mismatch"
    assert File.exists?(Path.join([home, ".lemon", "versions"]))
    assert File.read!(Path.join(home, ".zshrc")) =~ "added by the lemon installer"
  end

  test "a wrong digest in JSON mode reports the expected digest", %{opts: opts} do
    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          send(self(), {:code, UninstallCommand.run(["--json", "--confirm", "nope"], opts)})
        end)
      end)

    assert_received {:code, 1}
    payload = Jason.decode!(output)
    assert payload["ok"] == false
    assert payload["error"] == "digest_mismatch"
    assert payload["expected_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    assert payload["provided_digest"] == "nope"
  end
end
