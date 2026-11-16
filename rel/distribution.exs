defmodule Lemon.DistributionRelease do
  @moduledoc false

  # Apply after :assemble, before :tar. Refuse changed upstream templates rather
  # than accidentally shipping a release that exposes its cookie in argv.
  def secure(release) do
    launcher = Path.join([release.path, "bin", Atom.to_string(release.name)])
    source = File.read!(launcher)
    cookie_option = ~S(--cookie "$RELEASE_COOKIE")

    unless length(String.split(source, cookie_option)) == 5 do
      Mix.raise("Unsupported Elixir release launcher: expected four cookie arguments")
    end

    source =
      String.replace(
        source,
        cookie_option,
        ~S(--erl "-kernel start_distribution false -nocookie")
      )

    if source =~ "--cookie" or source =~ "-setcookie" do
      Mix.raise("Unsupported Elixir release launcher: unhandled cookie argument")
    end

    File.write!(launcher, source)

    iex = Path.join(release.version_path, "iex")
    iex_source = File.read!(iex)
    user_option = ~S(-user elixir)

    unless length(String.split(iex_source, user_option)) == 2 do
      Mix.raise("Unsupported IEx release launcher: expected one user driver")
    end

    File.write!(
      iex,
      String.replace(iex_source, user_option, "-user Elixir.LemonCli.Distribution")
    )

    for name <- Map.keys(release.boot_scripts) do
      path = Path.join(release.version_path, Atom.to_string(name))

      {:ok, [{:script, version, instructions}]} =
        :file.consult(String.to_charlist(path <> ".script"))

      kernel_start = {:apply, {:application, :start_boot, [:kernel, :permanent]}}

      unless Enum.count(instructions, &(&1 == kernel_start)) == 1 do
        Mix.raise("Unsupported OTP release boot script: expected one kernel start")
      end

      instructions =
        Enum.flat_map(instructions, fn
          ^kernel_start -> [kernel_start, {:apply, {LemonCli.Distribution, :boot, []}}]
          instruction -> [instruction]
        end)

      script = {:script, version, instructions}
      File.write!(path <> ".script", :io_lib.format(~c"~tp.~n", [script]))
      File.write!(path <> ".boot", :erlang.term_to_binary(script))
    end

    release
  end
end
