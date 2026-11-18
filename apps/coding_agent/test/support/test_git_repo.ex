defmodule CodingAgent.TestGitRepo do
  @moduledoc false

  # A minimal real Git repository marker: `LemonCore.TrustedRoot` ignores an
  # empty `.git` file or directory.
  def init!(dir) do
    File.mkdir_p!(Path.join(dir, ".git/objects"))
    File.mkdir_p!(Path.join(dir, ".git/refs"))
    File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")
    dir
  end

  # Point HOME at `home` with an operator config allowing project stream rules
  # under `root`; restores HOME when the calling test exits. Callers must not
  # be async.
  def allow_project_stream_rules!(home, root) do
    previous = System.get_env("HOME")
    File.mkdir_p!(Path.join(home, ".lemon"))

    File.write!(
      Path.join(home, ".lemon/config.toml"),
      "[rules]\nallow_project_stream_rules = [#{inspect(root)}]\n"
    )

    System.put_env("HOME", home)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
    end)

    home
  end
end
