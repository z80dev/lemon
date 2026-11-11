defmodule LemonCli.ServiceCommand do
  @moduledoc """
  CLI adapter for Lemon background system service management (`lemon service`).

  Supports `install`, `status`, `repair`, and `uninstall` subcommands across
  `controller`, `backend`, and `worker` roles (with `tunnel` reserved).

  ## Exit codes

  - `0`: Success — all requested units reached ready/online within wait timeout
    (or all reported units are ready on status, or units successfully uninstalled).
  - `1`: Operational failure or not-ready state.
  - `2`: Usage error — invalid subcommand, invalid flags, missing roles, or missing
    required worker arguments.

  ## Output

  With `--json`, emits exactly one sanitized schema 1 JSON document on stdout.
  Diagnostics, prompts, and progress messages are directed to stderr.
  """

  alias LemonCli.CommandRegistry

  @allowed_roles ~w(controller backend worker tunnel)

  @install_switches [
    name: :string,
    controller: :string,
    cwd: :string,
    allowed_root: [:string, :keep],
    invite_code_stdin: :boolean,
    exec_wrapper: :string,
    bot: :string,
    ssh: :string,
    node_port: :integer,
    gateway_port: :integer,
    product_port: :integer,
    backend_port: :integer,
    wait: :integer,
    manual: :boolean,
    enable_linger: :boolean,
    json: :boolean
  ]

  @status_switches [
    name: :string,
    json: :boolean
  ]

  @repair_switches [
    name: :string,
    exec_wrapper: :string,
    wait: :integer,
    enable_linger: :boolean,
    json: :boolean
  ]

  @uninstall_switches [
    name: :string,
    json: :boolean
  ]

  @name_regex ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(args, overrides \\ []) do
    if help_requested?(args) do
      print_help()
      0
    else
      case parse_args(args) do
        {:ok, subcommand, roles, opts} ->
          case resolve_options(subcommand, roles, opts, overrides) do
            {:ok, resolved_opts} ->
              {:ok, _apps} = ensure_started()
              execute(subcommand, roles, resolved_opts)

            {:error, message} ->
              usage_error(message)
          end

        {:error, message} ->
          usage_error(message)
      end
    end
  end

  defp help_requested?(args) do
    Enum.any?(args, &(&1 in ["--help", "-h", "help"]))
  end

  defp parse_args([]) do
    {:error, "Subcommand required: install, status, repair, or uninstall"}
  end

  defp parse_args([subcommand | rest]) when subcommand in ~w(install status repair uninstall) do
    switches = switches_for(subcommand)

    case OptionParser.parse(rest, strict: switches) do
      {parsed_opts, positionals, []} ->
        with :ok <- validate_roles(subcommand, positionals),
             :ok <- validate_worker_name(positionals, parsed_opts),
             :ok <- validate_wait(parsed_opts) do
          {:ok, subcommand, positionals, parsed_opts}
        end

      {_parsed, _positionals, invalid} ->
        flag = invalid |> hd() |> elem(0)
        {:error, "Invalid option: #{flag}"}
    end
  end

  defp parse_args([unknown | _]) do
    {:error, "Unknown subcommand: #{unknown}"}
  end

  defp switches_for("install"), do: @install_switches
  defp switches_for("status"), do: @status_switches
  defp switches_for("repair"), do: @repair_switches
  defp switches_for("uninstall"), do: @uninstall_switches

  defp validate_roles(subcommand, roles) when subcommand in ["install", "uninstall"] do
    cond do
      roles == [] ->
        {:error,
         "`lemon service #{subcommand}` requires at least one role: #{Enum.join(@allowed_roles, ", ")}"}

      not Enum.all?(roles, &(&1 in @allowed_roles)) ->
        unknown = Enum.find(roles, &(&1 not in @allowed_roles))
        {:error, "Unknown role `#{unknown}`; accepted roles: #{Enum.join(@allowed_roles, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_roles(_subcommand, roles) do
    if Enum.all?(roles, &(&1 in @allowed_roles)) do
      :ok
    else
      unknown = Enum.find(roles, &(&1 not in @allowed_roles))
      {:error, "Unknown role `#{unknown}`; accepted roles: #{Enum.join(@allowed_roles, ", ")}"}
    end
  end

  defp validate_worker_name(roles, opts) do
    name = opts[:name]

    cond do
      Enum.any?(roles, &(&1 in ["worker", "tunnel"])) and (is_nil(name) or name == "") ->
        {:error, "--name is required for worker or tunnel"}

      name && not Regex.match?(@name_regex, name) ->
        {:error, "--name must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"}

      true ->
        :ok
    end
  end

  defp validate_wait(opts) do
    case Keyword.fetch(opts, :wait) do
      {:ok, wait} when is_integer(wait) and wait >= 0 -> :ok
      {:ok, _} -> {:error, "--wait must be a non-negative integer"}
      :error -> :ok
    end
  end

  defp resolve_options(subcommand, roles, parsed_opts, overrides) do
    json? = parsed_opts[:json] == true

    opts_with_wait = parsed_opts

    with {:ok, invite_opts} <- handle_invite_code(subcommand, roles, opts_with_wait, overrides) do
      merged =
        invite_opts
        |> Keyword.merge(overrides)
        |> Keyword.put(:json, json?)

      {:ok, merged}
    end
  end

  defp handle_invite_code("install", roles, opts, overrides) do
    if opts[:invite_code_stdin] do
      if roles != ["worker"] do
        {:error, "--invite-code-stdin is valid only when installing the worker role alone"}
      else
        case read_invite_code(overrides) do
          {:ok, code} ->
            clean_opts = Keyword.delete(opts, :invite_code_stdin)
            {:ok, Keyword.put(clean_opts, :invite_code, code)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:ok, opts}
    end
  end

  defp handle_invite_code(_subcommand, _roles, opts, _overrides), do: {:ok, opts}

  defp read_invite_code(overrides) do
    case Keyword.fetch(overrides, :invite_code) do
      {:ok, code} when is_binary(code) ->
        validate_invite_code(code)

      _ ->
        case :io.request(:standard_io, {:get_chars, :latin1, ~c"", 45}) do
          <<code::binary-size(43), "\n">> ->
            validate_invite_code(code)

          _ ->
            {:error, "expected a 43-character enrollment credential and newline on stdin"}
        end
    end
  end

  defp validate_invite_code(code) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, code) do
      {:ok, code}
    else
      {:error, "invalid enrollment credential on stdin"}
    end
  end

  defp execute(subcommand, roles, opts) do
    operation = String.to_existing_atom(subcommand)

    result =
      case operation do
        :install -> LemonCore.Service.install(roles, opts)
        :status -> LemonCore.Service.status(roles, opts)
        :repair -> LemonCore.Service.repair(roles, opts)
        :uninstall -> LemonCore.Service.uninstall(roles, opts)
      end

    case result do
      {:ok, doc} ->
        render_document(subcommand, doc, opts[:json] == true)
        calculate_exit_code(subcommand, doc)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_reason(reason)}")

        if opts[:json] do
          IO.puts(
            Jason.encode!(%{
              schema: 1,
              manager: "none",
              persistence: "none",
              linger: nil,
              units: [],
              error: format_reason(reason)
            })
          )
        end

        1
    end
  end

  defp render_document(_subcommand, doc, true) do
    IO.puts(Jason.encode!(doc))
  end

  defp render_document(subcommand, doc, false) do
    IO.puts(format_human(subcommand, doc))
  end

  defp calculate_exit_code("uninstall", doc) do
    units = doc[:units] || []

    failed? =
      Enum.any?(units, fn unit ->
        state = unit[:state] || unit["state"]
        detail = unit[:detail] || unit["detail"]
        state == "failed" or (is_binary(detail) and detail not in ["", nil])
      end)

    if failed?, do: 1, else: 0
  end

  defp calculate_exit_code(_subcommand, doc) do
    units = doc[:units] || []

    if units != [] and Enum.all?(units, &unit_ready?/1) do
      0
    else
      1
    end
  end

  defp unit_ready?(unit) do
    state = unit[:state] || unit["state"]
    state in ["ready", "online"]
  end

  defp format_human(_subcommand, doc) do
    manager = doc[:manager] || doc["manager"]
    persistence = doc[:persistence] || doc["persistence"]
    units = doc[:units] || doc["units"] || []

    description =
      case persistence do
        "login" -> "starts when you log in"
        "boot" -> "starts at boot"
        "session" -> "runs while you are logged in"
        _ -> "does not restart automatically after reboot/logout"
      end

    header = "Service manager: #{manager} (persistence: #{persistence}); #{description}"

    if units == [] do
      header <> "\n  No service units found."
    else
      unit_lines =
        Enum.map(units, fn unit ->
          role = unit[:role] || unit["role"]
          name = unit[:name] || unit["name"]
          state = unit[:state] || unit["state"]
          pid = unit[:pid] || unit["pid"]
          log = unit[:log] || unit["log"]
          action = unit[:action] || unit["action"]
          detail = unit[:detail] || unit["detail"]

          label_part = if name, do: " (#{name})", else: ""
          pid_part = if pid, do: " (pid #{pid})", else: ""
          title = "  #{role}#{label_part}: #{state}#{pid_part}"

          details = []
          details = if action, do: details ++ ["action: #{action}"], else: details
          details = if detail, do: details ++ ["detail: #{detail}"], else: details
          details = if log, do: details ++ ["log: #{log}"], else: details

          if details == [] do
            title
          else
            title <> "\n    " <> Enum.join(details, "\n    ")
          end
        end)

      header <> "\n" <> Enum.join(unit_lines, "\n")
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp usage_error(message) do
    IO.puts(:stderr, "Error: #{message}")
    IO.puts(:stderr, "")
    IO.write(:stderr, usage_text())
    2
  end

  defp print_help do
    IO.write(CommandRegistry.help("service"))
  end

  defp usage_text do
    """
    Usage:
      lemon service install ROLE... [options]
      lemon service status [ROLE...] [options]
      lemon service repair [ROLE...] [options]
      lemon service uninstall ROLE... [options]

    Roles:
      controller, backend, worker

    Options:
      --name NAME            Worker execution node name (required for worker)
      --controller URL       Controller control-plane WebSocket URL
      --cwd PATH             Default working directory for worker units
      --allowed-root PATH    Allowed file/shell root for worker units (repeatable)
      --invite-code-stdin    Read one 43-character enrollment code from stdin
      --exec-wrapper PATH    Wrapper executable inside an .app bundle (macOS)
      --bot PATH             Executable path for backend service (lemon-bot)
      --wait SECS            Seconds to wait for units to reach ready (default: 120s controller, 60s backend/worker)
      --manual               Run units as unmanaged background processes
      --enable-linger        Enable systemd user linger for persistence after logout (Linux)
      --json                 Emit one sanitized schema 1 JSON document
    """
  end

  defp ensure_started do
    Application.ensure_all_started(:crypto)
  end
end
