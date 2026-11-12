defmodule LemonCli.TestRunnerTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("../../../..", __DIR__)

  test "test runner rejects unsupported Elixir before invoking Mix", %{tmp_dir: tmp_dir} do
    mix = Path.join(tmp_dir, "mix")
    File.write!(mix, "#!/bin/sh\nprintf 'mix reached\\n'\n")
    File.chmod!(mix, 0o755)

    for {version, expected_status} <- [
          {"1.20.4", 1},
          {"1.19.5", 1},
          {"1.20.5-rc.1", 1},
          {"invalid", 1},
          {"1.20.5", 0},
          {"1.20.6", 0},
          {"1.21.0", 0}
        ] do
      {output, status} =
        System.cmd("bash", [Path.join(@root, "scripts/test"), "path", "--help"],
          cd: @root,
          stderr_to_stdout: true,
          env: [
            {"PATH", tmp_dir <> ":" <> System.fetch_env!("PATH")},
            {"LEMON_TEST_ELIXIR_VERSION", version},
            {"LEMON_TEST_TMPDIR", tmp_dir},
            {"LEMON_STORE_PATH", Path.join(tmp_dir, "store")},
            {"ERL_FLAGS", "+S 1:1 +A 1"}
          ]
        )

      assert status == expected_status, output

      if expected_status == 1 do
        assert output =~ "requires Elixir 1.20.5 or newer"
        assert output =~ "found #{version}"
        refute output =~ "mix reached"
      else
        assert output =~ "mix reached"
      end
    end
  end
end
