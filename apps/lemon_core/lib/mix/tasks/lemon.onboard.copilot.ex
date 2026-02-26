defmodule Mix.Tasks.Lemon.Onboard.Copilot do
  use Mix.Task

  alias LemonCore.Config
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Secrets

  @default_secret_name "llm_github_copilot_api_key"
  @default_provider "github_copilot"
  @default_secret_provider "onboarding_copilot"
  @oauth_secret_provider "onboarding_copilot_oauth"

  @shortdoc "Interactive onboarding for GitHub Copilot provider"
  @moduledoc """
  Interactive onboarding flow for GitHub Copilot.

  What it does:
  - Runs GitHub Copilot OAuth device flow (URL + code) by default
  - Stores Copilot credentials in the encrypted Lemon secrets store
  - Writes `[providers.github_copilot].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.copilot

      mix lemon.onboard.copilot --token <token>
      mix lemon.onboard.copilot --enterprise-domain company.ghe.com
      mix lemon.onboard.copilot --token <token> --set-default
      mix lemon.onboard.copilot --token <token> --set-default --model gpt-5
      mix lemon.onboard.copilot --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")
    ensure_required_apps_started!()

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [
          token: :string,
          secret_name: :string,
          config_path: :string,
          enterprise_domain: :string,
          skip_enable_models: :boolean,
          set_default: :boolean,
          model: :string
        ]
      )

    ensure_secrets_ready!()

    {secret_value, secret_provider} = resolve_secret_payload!(opts)

    secret_name =
      require_non_empty!(opts[:secret_name] || @default_secret_name, "Invalid secret name.")

    config_path = opts[:config_path] || Config.global_path()

    secret_metadata = store_secret!(secret_name, secret_value, secret_provider)

    set_default? = resolve_set_default?(opts[:set_default])

    selected_model =
      if set_default? do
        choose_default_model!(opts[:model])
      else
        nil
      end

    update_config!(config_path, secret_name, selected_model)

    Mix.shell().info("")
    Mix.shell().info("GitHub Copilot onboarding complete.")
    Mix.shell().info("Secret: #{secret_metadata.name}")
    Mix.shell().info("Config: #{config_path}")

    Mix.shell().info(
      "Secret format: #{if secret_provider == @oauth_secret_provider, do: "oauth", else: "token"}"
    )

    if selected_model do
      Mix.shell().info("Default model: #{@default_provider}:#{selected_model}")
    end
  end

  defp ensure_required_apps_started! do
    [:lemon_core, :ai]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed to start required app #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp ensure_secrets_ready! do
    status = Secrets.status()

    unless status.configured do
      Mix.raise(
        "Encrypted secrets are not configured. Run mix lemon.secrets.init first, then retry."
      )
    end
  end

  defp resolve_secret_payload!(opts) do
    case opts[:token] do
      token when is_binary(token) and token != "" ->
        {
          require_non_empty!(token, "Token cannot be empty."),
          @default_secret_provider
        }

      _ ->
        enterprise_domain = resolve_enterprise_domain(opts[:enterprise_domain])
        enable_models? = !Keyword.get(opts, :skip_enable_models, false)

        oauth_payload =
          run_oauth_flow!(
            enterprise_domain: enterprise_domain,
            enable_models: enable_models?
          )

        {oauth_payload, @oauth_secret_provider}
    end
  end

  defp resolve_enterprise_domain(value) when is_binary(value) do
    String.trim(value)
  end

  defp resolve_enterprise_domain(_value) do
    Mix.shell().prompt("GitHub Enterprise URL/domain (blank for github.com): ")
    |> normalize_prompt_input()
  end

  defp run_oauth_flow!(opts) do
    oauth_module = Module.concat([Ai, Auth, GitHubCopilotOAuth])

    unless Code.ensure_loaded?(oauth_module) and
             function_exported?(oauth_module, :login_device_flow, 1) do
      Mix.raise("GitHub Copilot OAuth module is unavailable. Make sure the :ai app is compiled.")
    end

    login_opts = [
      enterprise_domain: blank_to_nil(Keyword.get(opts, :enterprise_domain)),
      enable_models: Keyword.get(opts, :enable_models, true),
      on_auth: fn url, instructions ->
        Mix.shell().info("")
        Mix.shell().info("Open this URL in your browser:")
        Mix.shell().info(url)

        if is_binary(instructions) and instructions != "" do
          Mix.shell().info(instructions)
        end

        maybe_open_url(url)

        Mix.shell().info("")
      end,
      on_progress: fn message ->
        Mix.shell().info(message)
      end
    ]

    oauth_secret =
      case apply(oauth_module, :login_device_flow, [login_opts]) do
        {:ok, secret} when is_map(secret) ->
          secret

        {:error, :invalid_enterprise_domain} ->
          Mix.raise("Invalid GitHub Enterprise URL/domain.")

        {:error, reason} ->
          Mix.raise("GitHub Copilot OAuth login failed: #{inspect(reason)}")
      end

    if function_exported?(oauth_module, :encode_secret, 1) do
      apply(oauth_module, :encode_secret, [oauth_secret])
    else
      Jason.encode!(oauth_secret)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_value), do: nil

  defp store_secret!(secret_name, secret_value, provider) do
    case Secrets.set(secret_name, secret_value, provider: provider) do
      {:ok, metadata} ->
        metadata

      {:error, :missing_master_key} ->
        Mix.raise(
          "Missing secrets master key. Run mix lemon.secrets.init or set LEMON_SECRETS_MASTER_KEY."
        )

      {:error, reason} ->
        Mix.raise("Failed to store Copilot credentials in secrets: #{inspect(reason)}")
    end
  end

  defp resolve_set_default?(value) when is_boolean(value), do: value

  defp resolve_set_default?(_value) do
    prompt_yes_no?("Set GitHub Copilot as your default provider?", false)
  end

  defp choose_default_model!(requested_model)
       when is_binary(requested_model) and requested_model != "" do
    requested_model = String.trim(requested_model)
    available = available_model_ids()

    if requested_model in available do
      requested_model
    else
      Mix.raise(
        "Unknown model #{inspect(requested_model)} for #{@default_provider}. Available: #{Enum.join(available, ", ")}"
      )
    end
  end

  defp choose_default_model!(_requested_model) do
    available = available_model_ids()

    if available == [] do
      Mix.raise("No models found for #{@default_provider} in Ai.Models registry.")
    end

    default_model = if "gpt-5" in available, do: "gpt-5", else: hd(available)

    Mix.shell().info("")
    Mix.shell().info("Available GitHub Copilot models:")

    Enum.with_index(available, 1)
    |> Enum.each(fn {model, idx} ->
      marker = if model == default_model, do: " (default)", else: ""
      Mix.shell().info("  #{idx}. #{model}#{marker}")
    end)

    choice = Mix.shell().prompt("Choose model number or id [default: #{default_model}]: ")

    parse_model_choice(choice, available, default_model)
  end

  defp parse_model_choice(choice, available, default_model) do
    trimmed = normalize_prompt_input(choice)

    cond do
      trimmed == "" ->
        default_model

      String.match?(trimmed, ~r/^\d+$/) ->
        idx = String.to_integer(trimmed)

        case Enum.at(available, idx - 1) do
          nil ->
            Mix.shell().error("Invalid index #{idx}.")
            parse_model_choice(Mix.shell().prompt("Choose model: "), available, default_model)

          model ->
            model
        end

      trimmed in available ->
        trimmed

      true ->
        Mix.shell().error("Unknown model #{inspect(trimmed)}.")
        parse_model_choice(Mix.shell().prompt("Choose model: "), available, default_model)
    end
  end

  defp available_model_ids do
    models_module = Module.concat([Ai, Models])

    if Code.ensure_loaded?(models_module) and function_exported?(models_module, :get_models, 1) do
      models_module
      |> apply(:get_models, [:github_copilot])
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp update_config!(config_path, secret_name, selected_model) do
    existing = read_existing_config!(config_path)

    content =
      existing
      |> TomlPatch.upsert_string("providers.github_copilot", "api_key_secret", secret_name)
      |> maybe_set_defaults(selected_model)

    validate_toml!(content, config_path)
    write_config!(config_path, content)
  end

  defp maybe_set_defaults(content, nil), do: content

  defp maybe_set_defaults(content, selected_model) do
    content
    |> TomlPatch.upsert_string("defaults", "provider", @default_provider)
    |> TomlPatch.upsert_string("defaults", "model", "#{@default_provider}:#{selected_model}")
  end

  defp read_existing_config!(config_path) do
    expanded = Path.expand(config_path)

    case File.read(expanded) do
      {:ok, content} ->
        validate_toml!(content, expanded)
        content

      {:error, :enoent} ->
        ""

      {:error, reason} ->
        Mix.raise("Failed to read config file #{expanded}: #{inspect(reason)}")
    end
  end

  defp write_config!(config_path, content) do
    expanded = Path.expand(config_path)
    File.mkdir_p!(Path.dirname(expanded))

    case File.write(expanded, content) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Failed to write config file #{expanded}: #{inspect(reason)}")
    end
  end

  defp validate_toml!("", _path), do: :ok

  defp validate_toml!(content, path) do
    case Toml.decode(content) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.raise("Config file #{path} is not valid TOML: #{inspect(reason)}")
    end
  end

  defp prompt_yes_no?(message, default) do
    suffix = if default, do: " [Y/n]: ", else: " [y/N]: "

    answer =
      Mix.shell().prompt(message <> suffix) |> normalize_prompt_input() |> String.downcase()

    case answer do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> prompt_yes_no?(message, default)
    end
  end

  defp maybe_open_url(url) do
    if prompt_yes_no?("Open this URL in your default browser now?", false) do
      case open_url_in_browser(url) do
        :ok ->
          Mix.shell().info("Opened browser.")

        {:error, reason} ->
          Mix.shell().error("Could not open browser automatically: #{inspect(reason)}")
      end
    end
  end

  defp open_url_in_browser(url) when is_binary(url) and url != "" do
    case :os.type() do
      {:unix, :darwin} ->
        run_system_cmd("open", [url])

      {:win32, _} ->
        run_system_cmd("cmd", ["/c", "start", "", url])

      {:unix, _} ->
        run_system_cmd("xdg-open", [url])

      _ ->
        {:error, :unsupported_os}
    end
  end

  defp open_url_in_browser(_url), do: {:error, :invalid_url}

  defp run_system_cmd(command, args), do: run_system_cmd(command, args, nil)

  defp run_system_cmd(command, args, input) when is_binary(command) and is_list(args) do
    if executable?(command) do
      opts =
        case input do
          nil -> [stderr_to_stdout: true]
          _ -> [input: input, stderr_to_stdout: true]
        end

      case System.cmd(command, args, opts) do
        {_output, 0} -> :ok
        {output, code} -> {:error, {:exit_code, code, output}}
      end
    else
      {:error, {:missing_executable, command}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp executable?(command) when is_binary(command) do
    System.find_executable(command) != nil
  end

  defp require_non_empty!(value, error_message) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: Mix.raise(error_message), else: trimmed
  end

  defp normalize_prompt_input(nil), do: ""
  defp normalize_prompt_input(:eof), do: ""

  defp normalize_prompt_input(value) when is_binary(value) do
    String.trim(value)
  end

  defp normalize_prompt_input(value) when is_list(value) do
    value |> List.to_string() |> String.trim()
  end

  defp normalize_prompt_input(value) do
    value |> to_string() |> String.trim()
  end
end
