defmodule LemonSkills.TestGitRepo do
  @moduledoc false

  # A minimal real Git repository marker: `LemonCore.TrustedRoot` ignores an
  # empty `.git` file or directory.
  def init!(dir) do
    File.mkdir_p!(Path.join(dir, ".git/objects"))
    File.mkdir_p!(Path.join(dir, ".git/refs"))
    File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")
    dir
  end
end
