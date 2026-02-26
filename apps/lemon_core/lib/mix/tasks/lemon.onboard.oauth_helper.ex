defmodule LemonCore.Onboarding.OAuthHelper do
  @moduledoc false

  alias LemonCore.Config
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Secrets

  @common_switches [
    token: :string,
    secret_name: :string,
    config_path: :string,
    set_default: :boolean,
    model: :string
  ]

  @type spec :: %{
          required(:display_name) => String.t(),
          required(:provider_key) => String.t(),
          required(:provider_table) => String.t(),
          required(:default_secret_name) => String.t(),
          required(:default_secret_provider) => String.t(),
          required(:oauth_secret_provider) => String.t(),
          required(:oauth_module) => module(),
          required(:preferred_models) => [String.t()],
          optional(:switches) => keyword(),
          optional(:oauth_opts_builder) => (keyword() -> keyword()),
          optional(:oauth_missing_hint) => String.t(),
          optional(:oauth_failure_label) => String.t(),
          optional(:token_resolution_hint) => String.t()
        }

  @spec run([String.t()], spec()) :: :ok
  def run(args, spec) when is_list(args) and is_map(spec) do
    Mix.Task.run("loadpaths")
    ensure_required_apps_started!()

    {opts, _positional, _invalid} =
      OptionParser.parse(args, switches: @common_switches ++ Map.get(spec, :switches, []))

    ensure_secrets_ready!()

    {secret_value, secret_provider} = resolve_secret_payload!(opts, spec)

    secret_name =
      require_non_empty!(
        opts[:secret_name] || spec.default_secret_name,
        "Invalid secret name."
      )

    config_path = opts[:config_path] || Config.global_path()

    secret_metadata = store_secret!(secret_name, secret_value, secret_provider, spec)

    set_default? = resolve_set_default?(opts[:set_default], spec)

    selected_model =
      if set_default? do
        choose_default_model!(opts[:model], spec)
      else
        nil
      end

    update_config!(config_path, secret_name, selected_model, spec)

    Mix.shell().info("")
    Mix.shell().info("#{spec.display_name} onboarding complete.")
    Mix.shell().info("Secret: #{secret_metadata.name}")
    Mix.shell().info("Config: #{config_path}")

    Mix.shell().info(
      "Secret format: #{if secret_provider == spec.oauth_secret_provider, do: "oauth", else: "token"}"
    )

    if selected_model do
      Mix.shell().info("Default model: #{spec.provider_key}:#{selected_model}")
    end

    :ok
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

  defp resolve_secret_payload!(opts, spec) do
    case opts[:token] do
      token when is_binary(token) and token != "" ->
        {
          require_non_empty!(token, "Token cannot be empty."),
          spec.default_secret_provider
        }

      _ ->
        oauth_payload = run_oauth_flow!(opts, spec)
        {oauth_payload, spec.oauth_secret_provider}
    end
  end

  defp run_oauth_flow!(opts, spec) do
    oauth_module = spec.oauth_module

    unless Code.ensure_loaded?(oauth_module) do
      Mix.raise(
        spec[:oauth_missing_hint] ||
          "#{spec.display_name} OAuth module is unavailable. Make sure the :ai app is compiled."
      )
    end

    oauth_opts =
      [
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
        end,
        on_prompt: fn prompt ->
          prompt_message =
            case prompt do
              %{message: message} when is_binary(message) and message != "" ->
                message

              message when is_binary(message) and message != "" ->
                message

              _ ->
                "Paste the authorization code or callback URL:"
            end

          Mix.shell().prompt("#{prompt_message} ")
        end
      ]
      |> then(fn base_opts ->
        if builder = spec[:oauth_opts_builder] do
          builder.(Keyword.merge(base_opts, opts))
        else
          base_opts
        end
      end)

    result =
      cond do
        function_exported?(oauth_module, :login_device_flow, 1) ->
          apply(oauth_module, :login_device_flow, [oauth_opts])

        function_exported?(oauth_module, :login_device_flow, 0) ->
          apply(oauth_module, :login_device_flow, [])

        function_exported?(oauth_module, :resolve_access_token, 0) ->
          apply(oauth_module, :resolve_access_token, [])

        true ->
          Mix.raise(
            "#{inspect(oauth_module)} does not expose a supported OAuth entrypoint. Expected login_device_flow/1 or resolve_access_token/0."
          )
      end

    normalize_oauth_result!(result, oauth_module, spec)
  end

  defp normalize_oauth_result!({:ok, payload}, oauth_module, _spec) do
    encode_oauth_payload!(payload, oauth_module)
  end

  defp normalize_oauth_result!({:error, reason}, _oauth_module, spec) do
    label = spec[:oauth_failure_label] || "#{spec.display_name} OAuth login failed"
    Mix.raise("#{label}: #{inspect(reason)}")
  end

  defp normalize_oauth_result!(payload, oauth_module, spec) do
    payload = encode_oauth_payload!(payload, oauth_module)

    if payload == "" do
      Mix.raise(
        spec[:token_resolution_hint] ||
          "#{spec.display_name} OAuth flow did not return credentials."
      )
    else
      payload
    end
  end

  defp encode_oauth_payload!(payload, oauth_module) when is_map(payload) do
    cond do
      function_exported?(oauth_module, :encode_secret, 1) ->
        apply(oauth_module, :encode_secret, [payload])

      true ->
        Jason.encode!(payload)
    end
  end

  defp encode_oauth_payload!(payload, _oauth_module) when is_binary(payload) do
    String.trim(payload)
  end

  defp encode_oauth_payload!(payload, _oauth_module) do
    Mix.raise("OAuth flow returned unsupported payload: #{inspect(payload)}")
  end

  defp store_secret!(secret_name, secret_value, secret_provider, spec) do
    case Secrets.set(secret_name, secret_value, provider: secret_provider) do
      {:ok, metadata} ->
        metadata

      {:error, :missing_master_key} ->
        Mix.raise(
          "Missing secrets master key. Run mix lemon.secrets.init or set LEMON_SECRETS_MASTER_KEY."
        )

      {:error, reason} ->
        Mix.raise(
          "Failed to store #{spec.display_name} credentials in secrets: #{inspect(reason)}"
        )
    end
  end

  defp resolve_set_default?(value, _spec) when is_boolean(value), do: value

  defp resolve_set_default?(_value, spec) do
    prompt_yes_no?("Set #{spec.display_name} as your default provider?", false)
  end

  defp choose_default_model!(requested_model, spec)
       when is_binary(requested_model) and requested_model != "" do
    requested_model = String.trim(requested_model)
    available = available_model_ids(spec)

    if requested_model in available do
      requested_model
    else
      Mix.raise(
        "Unknown model #{inspect(requested_model)} for #{spec.provider_key}. Available: #{Enum.join(available, ", ")}"
      )
    end
  end

  defp choose_default_model!(_requested_model, spec) do
    available = available_model_ids(spec)

    if available == [] do
      Mix.raise("No models found for #{spec.provider_key} in Ai.Models registry.")
    end

    default_model =
      Enum.find(spec.preferred_models, fn model -> model in available end) || hd(available)

    Mix.shell().info("")
    Mix.shell().info("Available #{spec.display_name} models:")

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

  defp available_model_ids(spec) do
    models_module = Module.concat([Ai, Models])

    with true <- Code.ensure_loaded?(models_module),
         true <- function_exported?(models_module, :get_models, 1),
         true <- function_exported?(models_module, :get_providers, 0),
         provider when not is_nil(provider) <-
           provider_atom_for_models(models_module, spec.provider_key) do
      models_module
      |> apply(:get_models, [provider])
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()
    else
      _ ->
        []
    end
  end

  defp provider_atom_for_models(models_module, provider_key) do
    normalized = String.downcase(provider_key)

    models_module
    |> apply(:get_providers, [])
    |> Enum.find(fn provider ->
      provider_str = Atom.to_string(provider)
      provider_str == normalized || String.replace(provider_str, "_", "-") == normalized
    end)
  end

  defp update_config!(config_path, secret_name, selected_model, spec) do
    existing = read_existing_config!(config_path)

    content =
      existing
      |> TomlPatch.upsert_string(spec.provider_table, "api_key_secret", secret_name)
      |> maybe_set_defaults(selected_model, spec)

    validate_toml!(content, config_path)
    write_config!(config_path, content)
  end

  defp maybe_set_defaults(content, nil, _spec), do: content

  defp maybe_set_defaults(content, selected_model, spec) do
    content
    |> TomlPatch.upsert_string("defaults", "provider", spec.provider_key)
    |> TomlPatch.upsert_string("defaults", "model", "#{spec.provider_key}:#{selected_model}")
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
