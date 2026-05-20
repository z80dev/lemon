defmodule Mix.Tasks.Lemon.Send do
  use Mix.Task

  alias LemonChannels.ScriptSend

  @requirements ["loadpaths"]
  @shortdoc "Send a Telegram or Discord notification from a script"
  @moduledoc """
  Send a Telegram or Discord notification from shell scripts, cron jobs, and CI.

  Usage:

      mix lemon.send --to telegram:<chat_id> "deploy finished"
      echo "RAM 92%" | mix lemon.send --to telegram:<chat_id>
      mix lemon.send --to telegram:<chat_id>:<thread_id> --subject "[CI]" --file report.txt
      mix lemon.send --to discord:<channel_id> "deploy finished"
      mix lemon.send --account work --to discord:#ops "deploy finished"
      mix lemon.send --to discord:#ops --thread deploys "deploy finished"
      mix lemon.send --to discord:#ops --reply-to 123456789 "deploy finished"
      mix lemon.send --to discord:<channel_id> --attach report.txt "artifact ready"
      mix lemon.send --dry-run --to discord:<channel_id> --attach report.txt "artifact ready"
      mix lemon.send --account work --list telegram

  Targets are intentionally limited to Telegram and Discord for now.
  `--account` selects the channel account id for delivery and known-target lookup.
  `--thread` / `--topic` sets the thread or topic separately from the target.
  `--reply-to` replies to an existing platform message id.
  `--file` reads the message body from a file; `--file -` forces stdin.
  `--attach` uploads a local file and may be repeated up to 10 times; any body text becomes the caption.
  `--dry-run` validates the target/body/attachments and prints the send summary without delivery.

  Default targets can be supplied through `LEMON_TELEGRAM_DEFAULT_CHAT_ID`,
  `LEMON_DISCORD_DEFAULT_CHANNEL_ID`, and optional `*_DEFAULT_THREAD_ID` vars.
  """

  @impl true
  def run(args) do
    case ScriptSend.parse_args(args) do
      {:ok, %{help: true} = parsed} ->
        print_help(parsed)

      {:ok, %{list: true} = parsed} ->
        print_list(parsed)

      {:ok, parsed} ->
        send_message(args, parsed)

      {:error, reason} ->
        fail(reason)
    end
  end

  defp print_help(%{json?: true}) do
    Mix.shell().info(Jason.encode!(%{usage: ScriptSend.usage()}, pretty: true))
  end

  defp print_help(%{quiet?: true}), do: :ok

  defp print_help(_parsed) do
    Mix.shell().info(ScriptSend.usage())
  end

  defp send_message(args, parsed) do
    case ScriptSend.run(args) do
      {:ok, result} ->
        print_success(parsed, result)

      {:error, reason} ->
        fail(reason)
    end
  end

  defp print_list(%{json?: true, targets: targets}) do
    Mix.shell().info(Jason.encode!(%{targets: targets}, pretty: true))
  end

  defp print_list(%{targets: targets, quiet?: quiet?}) do
    unless quiet? do
      Enum.each(targets, fn target ->
        default = target.default_target || "(none)"
        Mix.shell().info("#{target.platform}: #{target.target_format} default=#{default}")

        Enum.each(target.known_targets || [], fn known ->
          label = known.label || "(unlabeled)"
          aliases = alias_suffix(Map.get(known, :aliases, []))
          Mix.shell().info("  known #{known.target} label=#{inspect(label)}#{aliases}")
        end)

        if target.known_targets_truncated do
          Mix.shell().info("  known targets truncated count=#{target.known_target_count}")
        end
      end)
    end
  end

  defp print_success(%{json?: true}, result) do
    Mix.shell().info(Jason.encode!(Map.delete(result, :delivery), pretty: true))
  end

  defp print_success(%{quiet?: true}, _result), do: :ok

  defp print_success(_parsed, result) do
    thread =
      case result.thread_id do
        nil -> ""
        thread_id -> ":#{thread_id}"
      end

    verb = if result[:dry_run], do: "dry-run", else: "sent"

    message =
      "#{verb} #{result.content_bytes} bytes to #{result.platform}:#{result.target}#{thread}"
      |> maybe_append_attachment(result)

    Mix.shell().info(maybe_append_message_id(message, result.message_id))
  end

  defp fail(reason) do
    Mix.shell().error(error_message(reason))
    System.halt(exit_code(reason))
  end

  defp maybe_append_message_id(message, nil), do: message
  defp maybe_append_message_id(message, ""), do: message
  defp maybe_append_message_id(message, message_id), do: "#{message} message_id=#{message_id}"

  defp maybe_append_attachment(message, %{
         attachment_count: count,
         attachment_bytes: bytes
       })
       when is_integer(count) and count > 1 and is_integer(bytes),
       do: "#{message} attachments=#{count} attachment_bytes=#{bytes}"

  defp maybe_append_attachment(message, %{attachment_filename: filename, attachment_bytes: bytes})
       when is_binary(filename) and is_integer(bytes),
       do: "#{message} attachment=#{filename} attachment_bytes=#{bytes}"

  defp maybe_append_attachment(message, _result), do: message

  defp alias_suffix([]), do: ""
  defp alias_suffix(aliases) when is_list(aliases), do: " aliases=#{inspect(aliases)}"
  defp alias_suffix(_aliases), do: ""

  defp error_message(:missing_target), do: "missing --to target"
  defp error_message(:missing_body), do: "missing message body, --file, or piped stdin"
  defp error_message(:empty_body), do: "message body is empty"
  defp error_message(:missing_target_id), do: "target id is empty"
  defp error_message(:missing_attachment), do: "attachment path is empty"
  defp error_message(:missing_account_id), do: "account id is empty"
  defp error_message(:missing_thread_id), do: "thread id is empty"
  defp error_message(:missing_reply_to), do: "reply target id is empty"
  defp error_message(:conflicting_thread_options), do: "use only one of --thread or --topic"
  defp error_message(:conflicting_thread_target), do: "thread specified in both --to and --thread"
  defp error_message(:too_many_attachments), do: "too many --attach files"

  defp error_message({:too_many_attachments, max}),
    do: "at most #{max} --attach files are supported"

  defp error_message(:too_many_list_filters), do: "--list accepts at most one platform filter"

  defp error_message(:named_channel_not_supported),
    do: "named channels are not supported yet; use a numeric id"

  defp error_message({:named_channel_not_found, selector}),
    do: "named target not found: #{selector}"

  defp error_message({:ambiguous_named_channel, selector}),
    do: "named target is ambiguous: #{selector}"

  defp error_message({:missing_default_target, platform}),
    do: "missing default #{platform} target"

  defp error_message({:unsupported_platform, platform}),
    do: "unsupported platform #{inspect(platform)}"

  defp error_message({:invalid_options, invalid}), do: "invalid options: #{inspect(invalid)}"
  defp error_message({:file_read_failed, path, reason}), do: "could not read #{path}: #{reason}"
  defp error_message({:attachment_not_found, path}), do: "attachment not found: #{path}"
  defp error_message(reason), do: "send failed: #{inspect(reason)}"

  defp exit_code(:missing_target), do: 2
  defp exit_code(:missing_body), do: 2
  defp exit_code(:empty_body), do: 2
  defp exit_code(:missing_target_id), do: 2
  defp exit_code(:missing_attachment), do: 2
  defp exit_code(:missing_account_id), do: 2
  defp exit_code(:missing_thread_id), do: 2
  defp exit_code(:missing_reply_to), do: 2
  defp exit_code(:conflicting_thread_options), do: 2
  defp exit_code(:conflicting_thread_target), do: 2
  defp exit_code(:too_many_attachments), do: 2
  defp exit_code({:too_many_attachments, _max}), do: 2
  defp exit_code(:named_channel_not_supported), do: 2
  defp exit_code({:named_channel_not_found, _selector}), do: 2
  defp exit_code({:ambiguous_named_channel, _selector}), do: 2
  defp exit_code(:too_many_list_filters), do: 2
  defp exit_code({:missing_default_target, _platform}), do: 2
  defp exit_code({:unsupported_platform, _platform}), do: 2
  defp exit_code({:invalid_options, _invalid}), do: 2
  defp exit_code({:file_read_failed, _path, _reason}), do: 2
  defp exit_code({:attachment_not_found, _path}), do: 2
  defp exit_code(_reason), do: 1
end
