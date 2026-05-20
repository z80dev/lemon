defmodule Mix.Tasks.Lemon.Extension.Validate do
  use Mix.Task

  alias LemonCore.Extensions.Manifest

  @shortdoc "Validate Lemon extension package manifests"

  @moduledoc """
  Validates Lemon extension package manifests without loading extension code.

  ## Usage

      mix lemon.extension.validate PATH [PATH ...]
      mix lemon.extension.validate --json PATH

  Each path may be a manifest file or an extension directory. Directories are
  searched for `lemon_extension.json`, `extension.json`, and
  `.lemon-extension.json` at the top level and one directory below.
  """

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")

    {opts, paths, _invalid} =
      OptionParser.parse(args,
        switches: [json: :boolean],
        aliases: [j: :json]
      )

    validations = paths |> Enum.flat_map(&validate_path/1)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(%{manifests: Enum.map(validations, &json_validation/1)}))
    else
      print_validations(validations)
    end

    cond do
      paths == [] ->
        Mix.raise("Usage: mix lemon.extension.validate PATH [PATH ...]")

      validations == [] ->
        Mix.raise("No extension manifests found.")

      Enum.any?(validations, &(not &1.valid?)) ->
        Mix.raise("Extension manifest validation failed.")

      true ->
        :ok
    end
  end

  defp validate_path(path) do
    path = Path.expand(path)

    cond do
      File.dir?(path) -> Enum.map(Manifest.discover(path), &Manifest.validate_file/1)
      File.regular?(path) -> [Manifest.validate_file(path)]
      true -> []
    end
  end

  defp print_validations([]), do: Mix.shell().info("No extension manifests found.")

  defp print_validations(validations) do
    Enum.each(validations, fn validation ->
      status = if validation.valid?, do: "PASS", else: "FAIL"
      Mix.shell().info("#{status} #{validation.path}")

      if validation.capabilities != [] do
        Mix.shell().info("  capabilities: #{Enum.join(validation.capabilities, ", ")}")
      end

      if validation.provider_types != [] do
        Mix.shell().info("  provider types: #{Enum.join(validation.provider_types, ", ")}")
      end

      Enum.each(validation.errors, &Mix.shell().error("  - #{&1}"))
    end)
  end

  defp json_validation(validation) do
    %{
      path: validation.path,
      valid: validation.valid?,
      byteSize: validation.byte_size,
      errors: validation.errors,
      capabilities: validation.capabilities,
      providerTypes: validation.provider_types,
      hostTypes: validation.host_types,
      distributionSources: validation.distribution_sources,
      auditStatuses: validation.audit_statuses
    }
  end
end
