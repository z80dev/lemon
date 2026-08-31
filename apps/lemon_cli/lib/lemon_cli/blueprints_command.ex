defmodule LemonCli.BlueprintsCommand do
  @moduledoc """
  Catalog-scoped CLI adapter for portable skill and automation blueprints.

  Every operation is delegated to the authenticated, long-running control
  plane. The one-shot CLI VM therefore never accepts bundle paths, starts a
  second scheduler, or implements activation semantics independently.

  Running the family without arguments lists the catalog. Supplying a bundle
  ID and `--profile` without a subcommand previews activation; mutation is
  available only through the explicit `activate` subcommand with the exact
  digest returned by a fresh preview.
  """

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @digest_regex ~r/^[a-f0-9]{64}$/
  @control_regex ~r/[\x00-\x1F\x7F]/u
  @bidi_regex ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @common [json: :boolean]
  @profile [profile: :string]
  @activation [confirm: :string]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) when is_list(args) do
    case args do
      [] -> list([])
      ["--" <> _option | _rest] -> list(args)
      ["list" | rest] -> list(rest)
      ["inspect" | rest] -> review("blueprints.inspect", rest)
      ["validate" | rest] -> review("blueprints.validate", rest)
      ["preview" | rest] -> preview(rest)
      ["activate" | rest] -> activate(rest)
      [bundle_id | rest] -> preview([bundle_id | rest])
    end
  end

  defp list(args) do
    with {:ok, opts, []} <- parse(args, @common),
         {:ok, payload} <- request("blueprints.list", %{}) do
      output(payload, opts, &print_list/1)
      @exit_ok
    else
      {:ok, _opts, _rest} -> usage_error("Usage: lemon blueprints list [--json]")
      {:error, {:usage, message}} -> usage_error(message)
      {:error, reason} -> operation_error(reason, json_requested?(args))
    end
  end

  defp review(method, args) do
    with {:ok, opts, [bundle_id]} <- parse(args, @common),
         :ok <- validate_id(bundle_id, "Bundle ID"),
         {:ok, payload} <- request(method, %{"bundleId" => bundle_id}) do
      output(payload, opts, &print_review/1)
      @exit_ok
    else
      {:ok, _opts, _rest} ->
        usage_error("Usage: lemon blueprints #{operation_name(method)} <bundle-id> [--json]")

      {:error, {:usage, message}} ->
        usage_error(message)

      {:error, reason} ->
        operation_error(reason, json_requested?(args))
    end
  end

  defp preview(args) do
    with {:ok, opts, [bundle_id]} <- parse(args, @common ++ @profile),
         :ok <- validate_id(bundle_id, "Bundle ID"),
         :ok <- validate_id(opts[:profile], "Profile ID"),
         {:ok, payload} <-
           request("blueprints.preview", %{
             "bundleId" => bundle_id,
             "profileId" => opts[:profile]
           }) do
      output(payload, opts, &print_preview/1)
      @exit_ok
    else
      {:ok, _opts, _rest} ->
        usage_error("Usage: lemon blueprints preview <bundle-id> --profile <profile-id> [--json]")

      {:error, {:usage, message}} ->
        usage_error(message)

      {:error, reason} ->
        operation_error(reason, json_requested?(args))
    end
  end

  defp activate(args) do
    with {:ok, opts, [bundle_id]} <- parse(args, @common ++ @profile ++ @activation),
         :ok <- validate_id(bundle_id, "Bundle ID"),
         :ok <- validate_id(opts[:profile], "Profile ID"),
         :ok <- validate_digest(opts[:confirm]),
         {:ok, payload} <-
           request("blueprints.activate", %{
             "bundleId" => bundle_id,
             "profileId" => opts[:profile],
             "confirmationDigest" => opts[:confirm]
           }) do
      output(payload, opts, &print_activation/1)
      @exit_ok
    else
      {:ok, _opts, _rest} ->
        usage_error(
          "Usage: lemon blueprints activate <bundle-id> --profile <profile-id> --confirm <preview-digest> [--json]"
        )

      {:error, {:usage, message}} ->
        usage_error(message)

      {:error, reason} ->
        operation_error(reason, json_requested?(args))
    end
  end

  defp parse(args, strict) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: strict)

    if invalid == [],
      do: {:ok, opts, rest},
      else: {:error, {:usage, "Invalid blueprint options"}}
  end

  defp validate_id(value, label) when is_binary(value) do
    if Regex.match?(@id_regex, value),
      do: :ok,
      else: {:error, {:usage, "#{label} must be a lowercase safe identifier"}}
  end

  defp validate_id(_value, label),
    do: {:error, {:usage, "#{label} must be a lowercase safe identifier"}}

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value),
      do: :ok,
      else: {:error, {:usage, "--confirm must be the exact 64-character preview digest"}}
  end

  defp validate_digest(_),
    do: {:error, {:usage, "--confirm must be the exact 64-character preview digest"}}

  defp request(method, params), do: control_plane_client().request(method, params)

  defp control_plane_client do
    Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)
  end

  defp output(payload, opts, human_printer) do
    if opts[:json],
      do: IO.puts(Jason.encode!(payload, pretty: true)),
      else: human_printer.(payload)
  end

  defp print_list(%{"bundles" => []}), do: IO.puts("No valid blueprints in the local catalog.")

  defp print_list(%{"bundles" => bundles, "summary" => summary}) when is_list(bundles) do
    Enum.each(bundles, fn bundle ->
      IO.puts(
        "#{bundle["id"]}\t#{bundle["name"]}\t#{count(bundle["skills"])} skill(s)\t#{count(bundle["automations"])} automation(s)"
      )
    end)

    if summary["invalidBundleCount"] > 0 do
      IO.puts("Skipped invalid catalog entries: #{summary["invalidBundleCount"]}")
    end
  end

  defp print_list(_payload), do: IO.puts("Blueprint catalog returned no valid entries.")

  defp print_review(payload) do
    IO.puts("Blueprint: #{payload["id"]} (#{payload["name"]})")
    IO.puts("Manifest digest: #{payload["manifestDigest"]}")
    IO.puts("Validation: #{get_in(payload, ["validation", "auditStatus"])}")

    Enum.each(payload["skills"] || [], fn skill ->
      IO.puts(
        "Skill #{skill["key"]}: #{skill["auditStatus"]}, #{skill["fileCount"]} file(s), hash #{skill["bundleHash"]}"
      )
    end)

    Enum.each(payload["automations"] || [], fn automation ->
      IO.puts(
        "Automation #{automation["id"]}: #{automation["schedule"]} #{automation["timezone"]}, enabled=#{automation["enabled"]}, promptBytes=#{automation["promptBytes"]}"
      )
    end)
  end

  defp print_preview(payload) do
    profile = payload["profile"] || %{}
    automation = payload["automation"] || %{}

    IO.puts("Blueprint: #{payload["bundleId"]}")
    IO.puts("Profile: #{profile["id"]} (#{profile["canonicalSessionKey"]})")
    IO.puts("Can activate: #{payload["canActivate"]}")

    Enum.each(payload["skills"] || [], fn skill ->
      IO.puts("Skill #{skill["key"]}: #{skill["action"]}, hash #{skill["bundleHash"]}")
    end)

    IO.puts(
      "Automation #{automation["id"]}: #{automation["action"]}, #{automation["schedule"]} #{automation["timezone"]}, enabled=#{automation["enabled"]}, promptBytes=#{automation["promptBytes"]}"
    )

    IO.puts("Confirmation digest: #{payload["confirmationDigest"]}")

    if payload["canActivate"] do
      IO.puts(
        "Activate with: lemon blueprints activate #{payload["bundleId"]} --profile #{profile["id"]} --confirm #{payload["confirmationDigest"]}"
      )
    end
  end

  defp print_activation(payload) do
    IO.puts(
      "Blueprint activation result: #{payload["bundleId"]} for profile #{payload["profileId"]}"
    )

    Enum.each(payload["skills"] || [], fn skill ->
      IO.puts("Skill #{skill["key"]}: #{skill["status"]}")
    end)

    automation = payload["automation"] || %{}
    IO.puts("Automation #{automation["id"]}: #{automation["status"]}")
    IO.puts("Duplicate-safe: #{get_in(payload, ["summary", "duplicateSafe"])}")
  end

  defp count(value) when is_list(value), do: length(value)
  defp count(_), do: 0

  defp operation_name("blueprints." <> operation), do: operation

  defp json_requested?(args), do: "--json" in args

  defp operation_error(reason, json?) do
    {code, message} = safe_error(reason)

    if json? do
      IO.puts(
        :stderr,
        Jason.encode!(%{"ok" => false, "error" => %{"code" => code, "message" => message}})
      )
    else
      IO.puts(:stderr, "Blueprint operation failed [#{code}]: #{message}")
    end

    @exit_error
  end

  defp safe_error({:control_plane, error}) when is_map(error) do
    code = safe_code(error["code"])
    message = safe_message(error["message"])
    {code, message}
  end

  defp safe_error({:control_plane_unavailable, _reason}),
    do: {"CONTROL_PLANE_UNAVAILABLE", "The Lemon control plane is unavailable"}

  defp safe_error(:control_plane_timeout),
    do: {"CONTROL_PLANE_TIMEOUT", "The Lemon control plane did not respond in time"}

  defp safe_error(_reason), do: {"OPERATION_FAILED", "Blueprint operation failed"}

  defp safe_code(code)
       when code in ~w(INVALID_REQUEST INVALID_PARAMS NOT_FOUND CONFLICT FORBIDDEN UNAUTHORIZED UNAVAILABLE TIMEOUT),
       do: code

  defp safe_code(_), do: "OPERATION_FAILED"

  defp safe_message(message) when is_binary(message) and byte_size(message) <= 512 do
    if String.valid?(message) and not Regex.match?(@control_regex, message) and
         not Regex.match?(@bidi_regex, message) do
      message
    else
      "Blueprint operation failed"
    end
  end

  defp safe_message(_), do: "Blueprint operation failed"

  defp usage_error(message) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "Run `lemon blueprints --help` for command options.")
    @exit_usage
  end
end
