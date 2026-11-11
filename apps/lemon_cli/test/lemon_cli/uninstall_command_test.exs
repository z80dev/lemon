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

    # The command reads HOME and the launcher kind from the environment; pin
    # both so the preview describes this temporary layout, not the developer's.
    previous =
      Map.new(~w(HOME LEMON_CLI_LAUNCHER LEMON_LAUNCHER LEMON_UNINSTALL_MANIFEST), fn key ->
        {key, System.get_env(key)}
      end)

    System.put_env("HOME", home)
    System.put_env("LEMON_CLI_LAUNCHER", "release")
    System.delete_env("LEMON_LAUNCHER")
    System.delete_env("LEMON_UNINSTALL_MANIFEST")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    {:ok, home: home}
  end

  defp run(args) do
    result = %{code: nil}

    output =
      capture_io(fn ->
        send(self(), {:code, UninstallCommand.run(args)})
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

  test "the default run previews and prints a confirmation digest", %{home: home} do
    {output, %{code: 0}} = run([])

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

  test "--purge preview names the data directory and a different digest" do
    {plain, %{code: 0}} = run([])
    {purge, %{code: 0}} = run(["--purge"])

    assert purge =~ "Purge data (~/.lemon): yes"
    assert purge =~ "lemon uninstall --purge --confirm"

    [_, plain_digest] = Regex.run(~r/Confirmation digest: ([0-9a-f]{64})/, plain)
    [_, purge_digest] = Regex.run(~r/Confirmation digest: ([0-9a-f]{64})/, purge)
    refute plain_digest == purge_digest
  end

  test "--json preview emits the candidate set and digest", %{home: home} do
    {output, %{code: 0}} = run(["--json"])
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

  test "a wrong digest fails with exit 1 and changes nothing", %{home: home} do
    output =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 send(
                   self(),
                   {:code, UninstallCommand.run(["--confirm", String.duplicate("a", 64)])}
                 )
               end) == ""
      end)

    assert_received {:code, 1}
    assert output =~ "confirmation digest mismatch"
    assert File.exists?(Path.join([home, ".lemon", "versions"]))
    assert File.read!(Path.join(home, ".zshrc")) =~ "added by the lemon installer"
  end

  test "a wrong digest in JSON mode reports the expected digest" do
    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          send(self(), {:code, UninstallCommand.run(["--json", "--confirm", "nope"])})
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
