defmodule LemonCore.Service.Unit do
  @moduledoc "Pure launchd and systemd renderers and bounded, non-executing unit readers."

  alias LemonCore.Service.Role

  def render(spec, "launchd") do
    env =
      spec.env
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} ->
        "<key>#{xml(key)}</key><string>#{xml(value)}</string>"
      end)

    argv = Enum.map_join(spec.argv, "\n", &"<string>#{xml(&1)}</string>")

    configured =
      if spec.role == "backend",
        do: "<key>LemonBotLauncher</key><string>#{xml(List.first(spec.argv))}</string>",
        else: ""

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>#{xml(spec.label)}</string>
    <key>ProgramArguments</key><array>#{argv}</array>
    #{configured}
    <key>EnvironmentVariables</key><dict>#{env}</dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Standard</string>
    <key>WorkingDirectory</key><string>#{xml(spec.home)}</string>
    <key>StandardOutPath</key><string>#{xml(spec.log)}</string>
    <key>StandardErrorPath</key><string>#{xml(spec.log)}</string>
    </dict></plist>
    """
  end

  def render(spec, "systemd") do
    name = if spec.name, do: " name=#{spec.name}", else: ""

    environment =
      spec.env
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} ->
        "Environment=" <> quote_systemd(key <> "=" <> value, false)
      end)

    """
    # Managed by lemon service (role=#{spec.role}#{name}) — edits are overwritten
    [Unit]
    Description=Lemon #{spec.role}
    [Service]
    Type=simple
    ExecStart=#{Enum.map_join(spec.argv, " ", &quote_systemd/1)}
    WorkingDirectory=%h
    #{environment}
    Restart=on-failure
    RestartPreventExitStatus=2
    RestartSec=5
    TimeoutStopSec=30
    StandardOutput=append:#{spec.log}
    StandardError=append:#{spec.log}
    [Install]
    WantedBy=default.target
    """
  end

  def render(spec, "none"),
    do: Jason.encode!(Map.take(spec, [:role, :name, :argv, :env, :port, :log])) <> "\n"

  def read(path, manager) do
    with {:ok, %{type: :regular, size: size}} when size <= 131_072 <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, parsed} <- parse(body, manager) do
      {:ok, Map.put(parsed, :body, body)}
    else
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :invalid_unit}
    end
  end

  def parse(body, "launchd") do
    with [[_, array]] <-
           Regex.scan(~r/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/s, body),
         [[_, label]] <- Regex.scan(~r/<key>Label<\/key>\s*<string>(.*?)<\/string>/s, body),
         argv when argv != [] <-
           Regex.scan(~r/<string>(.*?)<\/string>/s, array)
           |> Enum.map(fn [_, value] -> unxml(value) end) do
      env =
        case Regex.run(~r/<key>EnvironmentVariables<\/key>\s*<dict>(.*?)<\/dict>/s, body) do
          [_, dict] ->
            Regex.scan(~r/<key>(.*?)<\/key>\s*<string>(.*?)<\/string>/s, dict)
            |> Map.new(fn [_, key, value] -> {unxml(key), unxml(value)} end)

          _ ->
            %{}
        end

      configured =
        case Regex.run(~r/<key>LemonBotLauncher<\/key>\s*<string>(.*?)<\/string>/s, body) do
          [_, value] -> unxml(value)
          _ -> nil
        end

      {:ok,
       %{argv: argv, env: env, label: unxml(label), configured_bot: configured, managed: false}}
    else
      _ -> {:error, :invalid_unit}
    end
  end

  def parse(body, "systemd") do
    with [_, command] <- Regex.run(~r/^ExecStart=(.+)$/m, body),
         {:ok, argv} <- split_command(command),
         true <- argv != [] do
      env =
        Regex.scan(~r/^Environment=(.+)$/m, body)
        |> Enum.reduce(%{}, fn [_, value], acc ->
          case split_command(value, :environment) do
            {:ok, [pair]} ->
              case String.split(pair, "=", parts: 2) do
                [key, item] -> Map.put(acc, key, item)
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      {:ok,
       %{
         argv: argv,
         env: env,
         managed: String.starts_with?(body, "# Managed by lemon service (role=")
       }}
    else
      _ -> {:error, :invalid_unit}
    end
  end

  def parse(body, "none") do
    case Jason.decode(body) do
      {:ok, %{"argv" => argv, "env" => env} = record} when is_list(argv) and is_map(env) ->
        if argv != [] and Enum.all?(argv, &is_binary/1) and
             Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
          configured = if record["role"] == "backend", do: List.first(argv), else: nil
          {:ok, %{argv: argv, env: env, configured_bot: configured, managed: false}}
        else
          {:error, :invalid_unit}
        end

      _ ->
        {:error, :invalid_unit}
    end
  end

  def owned?(parsed, spec, opts) do
    argv =
      case parsed.argv do
        [_wrapper, "--" | args] -> args
        args -> args
      end

    expected_bot =
      Keyword.get(opts, :bot, Path.join([Role.home(opts), ".local", "bin", "lemon-bot"]))

    program_owned =
      case {spec.role, argv} do
        {"backend", [program | _]} ->
          program == expected_bot or
            (program == Map.get(parsed, :configured_bot) and
               parsed.env["LEMON_SERVICE_ROLE"] == "backend") or
            String.starts_with?(
              program,
              Path.join(Role.home(opts), ".lemon/lemon_bot/versions") <> "/"
            )

        {_, [program | _]} ->
          String.ends_with?(program, "/bin/lemon")

        _ ->
          false
      end

    (not Map.has_key?(parsed, :label) or parsed.label == spec.label) and
      (parsed.managed or program_owned)
  end

  def write(spec, manager) do
    File.mkdir_p!(Path.dirname(spec.path))
    File.mkdir_p!(Path.dirname(spec.log))
    atomic_write(spec.path, render(spec, manager), if(manager == "none", do: 0o600, else: 0o644))
  rescue
    _ -> {:error, :unit_write_failed}
  end

  def atomic_write(path, content, mode) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.write(tmp, content, [:exclusive]),
           :ok <- File.chmod(tmp, mode),
           :ok <- File.rename(tmp, path),
           do: :ok
    after
      File.rm(tmp)
    end
  end

  def quote_systemd(value, expand_dollars \\ true) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("%", "%%")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    "\"" <> if(expand_dollars, do: String.replace(escaped, "$", "$$"), else: escaped) <> "\""
  end

  def split_command(value, mode \\ :exec) do
    case tokenize(String.to_charlist(value), [], [], nil) do
      {:ok, words} ->
        {:ok,
         Enum.map(words, fn word ->
           word = if mode == :process, do: word, else: String.replace(word, "%%", "%")
           if mode == :exec, do: String.replace(word, "$$", "$"), else: word
         end)}

      error ->
        error
    end
  end

  defp tokenize([], word, words, nil), do: {:ok, finish_word(word, words) |> Enum.reverse()}
  defp tokenize([], _, _, _), do: {:error, :invalid_unit}

  defp tokenize([?\\, next | rest], word, words, quote),
    do: tokenize(rest, [unescape(next) | word], words, quote)

  defp tokenize([char | rest], word, words, nil) when char in [32, 9],
    do: tokenize(rest, [], finish_word(word, words), nil)

  defp tokenize([char | rest], word, words, nil) when char in [34, 39],
    do: tokenize(rest, word, words, char)

  defp tokenize([char | rest], word, words, char), do: tokenize(rest, word, words, nil)

  defp tokenize([char | rest], word, words, quote),
    do: tokenize(rest, [char | word], words, quote)

  defp finish_word([], words), do: words
  defp finish_word(word, words), do: [word |> Enum.reverse() |> to_string() | words]
  defp unescape(?n), do: ?\n
  defp unescape(?r), do: ?\r
  defp unescape(char), do: char

  defp xml(value),
    do:
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&apos;")

  defp unxml(value),
    do:
      value
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")
end
