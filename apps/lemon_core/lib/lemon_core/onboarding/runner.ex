defmodule LemonCore.Onboarding.Runner do
  @moduledoc false

  alias LemonCore.Config
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Onboarding.LogSilencer
  alias LemonCore.Onboarding.Provider
  alias LemonCore.Onboarding.TerminalUI
  alias LemonCore.Secrets

  @common_switches [
    token: :string,
    secret_name: :string,
    config_path: :string,
    set_default: :boolean,
    model: :string,
    auth: :string
  ]

  @type io_callbacks :: %{
          required(:info) => (String.t() -> any()),
          required(:error) => (String.t() -> any()),
          required(:prompt) => (String.t() -> String.t() | charlist() | nil),
          required(:secret) => (String.t() -> String.t() | charlist() | nil),
          optional(:select) => (map() -> any())
        }

  @spec default_io() :: io_callbacks()
  def default_io do
    shell = Mix.shell()

    %{
      info: fn message -> shell.info(message) end,
      error: fn message -> shell.error(message) end,
      prompt: fn prompt -> shell.prompt(prompt) end,
      secret: &read_secret/1,
      select: &TerminalUI.select/1
    }
  end

  @spec run([String.t()], Provider.t(), keyword()) :: :ok
  def run(args, %Provider{} = spec, opts \\ []) when is_list(args) do
    io = Keyword.get(opts, :io, default_io())

    LogSilencer.with_quiet_logs(interactive_tui_session?(io), fn ->
      do_run(args, spec, io)
    end)
  end

  defp do_run(args, %Provider{} = spec, io) do
    Mix.Task.run("loadpaths")
    ensure_required_apps_started!()

    {cli_opts, _positional, _invalid} =
      OptionParser.parse(args, switches: @common_switches ++ spec.switches)

    ensure_secrets_ready!()

    auth_mode = resolve_auth_mode!(cli_opts, spec, io)
    {secret_value, secret_provider} = resolve_secret_payload!(cli_opts, spec, auth_mode, io)

    secret_name =
      require_non_empty!(
        cli_opts[:secret_name] || spec.default_secret_name,
        "Invalid secret name."
      )

    config_path = cli_opts[:config_path] || Config.global_path()
    secret_metadata = store_secret!(secret_name, secret_value, secret_provider, spec)

    set_default? = resolve_set_default?(cli_opts[:set_default], spec, io)

    selected_model =
      if set_default? do
        choose_default_model!(cli_opts[:model], spec, io)
      else
        nil
      end

    update_config!(config_path, secret_name, selected_model, auth_mode, spec)

    io.info.("")
    io.info.("#{spec.display_name} onboarding complete.")
    io.info.("Secret: #{secret_metadata.name}")
    io.info.("Config: #{config_path}")
    io.info.("Authentication: #{auth_mode_output_label(auth_mode)}")

    if selected_model do
      io.info.("Default model: #{spec.id}:#{selected_model}")
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

  defp interactive_tui_session?(io) when is_map(io) do
    is_function(Map.get(io, :select), 1) and TerminalUI.available?()
  end

  defp ensure_secrets_ready! do
    status = Secrets.status()

    unless status.configured do
      Mix.raise(
        "Encrypted secrets are not configured. Run mix lemon.secrets.init first, then retry."
      )
    end
  end

  defp resolve_auth_mode!(opts, %Provider{} = spec, io) do
    token = normalize_optional_string(opts[:token])
    explicit_auth = normalize_optional_string(opts[:auth])

    cond do
      token && explicit_auth == "oauth" ->
        Mix.raise("Cannot combine --token with --auth oauth.")

      token ->
        :api_key

      explicit_auth ->
        parse_auth_mode!(explicit_auth, spec)

      spec.auth_modes == [:oauth] ->
        :oauth

      spec.auth_modes == [:api_key] ->
        :api_key

      true ->
        prompt_for_auth_mode!(spec, io)
    end
  end

  defp parse_auth_mode!(value, %Provider{} = spec) do
    mode =
      case String.downcase(value) do
        "oauth" -> :oauth
        "api_key" -> :api_key
        "api-key" -> :api_key
        other -> Mix.raise("Unknown auth mode #{inspect(other)} for #{spec.id}.")
      end

    if mode in spec.auth_modes do
      mode
    else
      supported =
        spec.auth_modes
        |> Enum.map(&Atom.to_string/1)
        |> Enum.join(", ")

      Mix.raise(
        "#{spec.display_name} does not support #{mode}. Supported auth modes: #{supported}"
      )
    end
  end

  defp prompt_for_auth_mode!(%Provider{} = spec, io) do
    default_mode = spec.default_auth_mode || hd(spec.auth_modes)
    default_index = Enum.find_index(spec.auth_modes, &(&1 == default_mode)) || 0

    options =
      spec.auth_modes
      |> Enum.with_index()
      |> Enum.map(fn {mode, idx} ->
        label =
          auth_mode_choice_label(spec, mode) <>
            if(idx == default_index, do: "   [default]", else: "")

        %{label: label, value: mode}
      end)

    case select_value(io, %{
           title: "Choose #{spec.display_name} Authentication",
           subtitle: "Pick how Lemon should store and use these credentials.",
           options: options
         }) do
      {:ok, mode} ->
        mode

      :cancel ->
        Mix.raise("Onboarding cancelled.")

      :fallback ->
        io.info.("")
        io.info.("Choose how to authenticate #{spec.display_name}:")

        spec.auth_modes
        |> Enum.with_index(1)
        |> Enum.each(fn {mode, idx} ->
          marker = if idx == default_index + 1, do: " (default)", else: ""
          io.info.("  #{idx}. #{auth_mode_choice_label(spec, mode)}#{marker}")
        end)

        prompt = "Choose authentication method [default: #{default_index + 1}]: "
        choice = io.prompt.(prompt)

        parse_auth_mode_choice(choice, spec, io, default_mode)
    end
  end

  defp parse_auth_mode_choice(choice, %Provider{} = spec, io, default_mode) do
    trimmed = normalize_prompt_input(choice)

    cond do
      trimmed == "" ->
        default_mode

      String.match?(trimmed, ~r/^\d+$/) ->
        idx = String.to_integer(trimmed)

        case Enum.at(spec.auth_modes, idx - 1) do
          nil ->
            io.error.("Invalid index #{idx}.")

            parse_auth_mode_choice(
              io.prompt.("Choose authentication method: "),
              spec,
              io,
              default_mode
            )

          mode ->
            mode
        end

      true ->
        try do
          parse_auth_mode!(trimmed, spec)
        rescue
          e in Mix.Error ->
            io.error.(Exception.message(e))

            parse_auth_mode_choice(
              io.prompt.("Choose authentication method: "),
              spec,
              io,
              default_mode
            )
        end
    end
  end

  defp resolve_secret_payload!(opts, %Provider{} = spec, auth_mode, io) do
    case normalize_optional_string(opts[:token]) do
      token when is_binary(token) ->
        {token, secret_provider_for_auth(spec, :api_key)}

      nil when auth_mode == :api_key ->
        prompt = spec.api_key_prompt || "Enter API key: "

        secret_value =
          io.secret.(prompt)
          |> normalize_prompt_input()
          |> require_non_empty!("Credential cannot be empty.")

        {secret_value, secret_provider_for_auth(spec, :api_key)}

      nil ->
        oauth_payload = run_oauth_flow!(opts, spec, io)
        {oauth_payload, secret_provider_for_auth(spec, :oauth)}
    end
  end

  defp secret_provider_for_auth(%Provider{} = spec, :oauth) do
    spec.oauth_secret_provider || spec.api_key_secret_provider
  end

  defp secret_provider_for_auth(%Provider{} = spec, :api_key), do: spec.api_key_secret_provider

  defp run_oauth_flow!(opts, %Provider{oauth_module: oauth_module} = spec, io) do
    unless oauth_module && Code.ensure_loaded?(oauth_module) do
      Mix.raise(
        spec.oauth_missing_hint ||
          "#{spec.display_name} OAuth module is unavailable. Make sure the :ai app is compiled."
      )
    end

    oauth_opts =
      [
        on_auth: fn url, instructions ->
          maybe_open_url(url, io)

          io.info.("")
          io.info.("Open this URL in your browser:")
          io.info.(url)

          if is_binary(instructions) and instructions != "" do
            io.info.("")
            io.info.(instructions)
          end

          io.info.("")
        end,
        on_progress: fn message ->
          io.info.(message)
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

          io.prompt.("#{prompt_message} ")
        end
      ]
      |> then(fn base_opts ->
        if builder = spec.oauth_opts_builder do
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
    label = spec.oauth_failure_label || "#{spec.display_name} OAuth login failed"
    Mix.raise("#{label}: #{inspect(reason)}")
  end

  defp normalize_oauth_result!(payload, oauth_module, spec) do
    payload = encode_oauth_payload!(payload, oauth_module)

    if payload == "" do
      Mix.raise(
        spec.token_resolution_hint ||
          "#{spec.display_name} OAuth flow did not return credentials."
      )
    else
      payload
    end
  end

  defp encode_oauth_payload!(payload, oauth_module) when is_map(payload) do
    if function_exported?(oauth_module, :encode_secret, 1) do
      apply(oauth_module, :encode_secret, [payload])
    else
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

  defp resolve_set_default?(value, _spec, _io) when is_boolean(value), do: value

  defp resolve_set_default?(_value, %Provider{} = spec, io) do
    prompt_yes_no?("Set #{spec.display_name} as your default provider?", false, io)
  end

  defp choose_default_model!(requested_model, %Provider{} = spec, _io)
       when is_binary(requested_model) and requested_model != "" do
    requested_model = String.trim(requested_model)
    available = available_model_ids(spec)

    if requested_model in available do
      requested_model
    else
      Mix.raise(
        "Unknown model #{inspect(requested_model)} for #{spec.id}. Available: #{Enum.join(available, ", ")}"
      )
    end
  end

  defp choose_default_model!(_requested_model, %Provider{} = spec, io) do
    available = available_model_ids(spec)

    if available == [] do
      Mix.raise("No models found for #{spec.id} in Ai.Models registry.")
    end

    default_model =
      Enum.find(spec.preferred_models, fn model -> model in available end) || hd(available)

    options =
      available
      |> Enum.map(fn model ->
        label = model <> if(model == default_model, do: "   [default]", else: "")
        %{label: label, value: model}
      end)

    case select_value(io, %{
           title: "Choose #{spec.display_name} Model",
           subtitle: "This sets defaults.provider and defaults.model in config.toml.",
           options: options
         }) do
      {:ok, model} ->
        model

      :cancel ->
        Mix.raise("Onboarding cancelled.")

      :fallback ->
        io.info.("")
        io.info.("Available #{spec.display_name} models:")

        available
        |> Enum.with_index(1)
        |> Enum.each(fn {model, idx} ->
          marker = if model == default_model, do: " (default)", else: ""
          io.info.("  #{idx}. #{model}#{marker}")
        end)

        choice = io.prompt.("Choose model number or id [default: #{default_model}]: ")
        parse_model_choice(choice, available, default_model, io)
    end
  end

  defp parse_model_choice(choice, available, default_model, io) do
    trimmed = normalize_prompt_input(choice)

    cond do
      trimmed == "" ->
        default_model

      String.match?(trimmed, ~r/^\d+$/) ->
        idx = String.to_integer(trimmed)

        case Enum.at(available, idx - 1) do
          nil ->
            io.error.("Invalid index #{idx}.")
            parse_model_choice(io.prompt.("Choose model: "), available, default_model, io)

          model ->
            model
        end

      trimmed in available ->
        trimmed

      true ->
        io.error.("Unknown model #{inspect(trimmed)}.")
        parse_model_choice(io.prompt.("Choose model: "), available, default_model, io)
    end
  end

  defp available_model_ids(%Provider{} = spec) do
    models_module = Module.concat([:"Elixir.Ai", :Models])

    with true <- Code.ensure_loaded?(models_module),
         true <- function_exported?(models_module, :get_models, 1),
         true <- function_exported?(models_module, :get_providers, 0),
         provider when not is_nil(provider) <-
           provider_atom_for_models(models_module, spec.id) do
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

  defp provider_atom_for_models(models_module, provider_id) do
    normalized = normalize_provider_name(provider_id)

    models_module
    |> apply(:get_providers, [])
    |> Enum.find(fn provider ->
      provider_str = provider |> Atom.to_string() |> normalize_provider_name()
      provider_str == normalized
    end)
  end

  defp update_config!(config_path, secret_name, selected_model, auth_mode, %Provider{} = spec) do
    existing = read_existing_config!(config_path)

    content =
      existing
      |> update_provider_auth_config(spec, auth_mode, secret_name)
      |> maybe_set_defaults(selected_model, spec)

    validate_toml!(content, config_path)
    write_config!(config_path, content)
  end

  defp update_provider_auth_config(content, %Provider{} = spec, auth_mode, secret_name) do
    selected_key = secret_config_key(spec, auth_mode)

    keys_to_clear =
      spec.secret_config_key_by_mode
      |> Map.values()
      |> Enum.uniq()
      |> Enum.reject(&(&1 == selected_key))

    content =
      Enum.reduce(keys_to_clear, content, fn key, acc ->
        TomlPatch.delete_key(acc, spec.provider_table, key)
      end)

    content =
      TomlPatch.upsert_string(content, spec.provider_table, selected_key, secret_name)

    case Map.get(spec.auth_source_by_mode, auth_mode) do
      source when is_binary(source) ->
        TomlPatch.upsert_string(content, spec.provider_table, "auth_source", source)

      _ ->
        content
    end
  end

  defp secret_config_key(%Provider{} = spec, auth_mode) do
    Map.get(spec.secret_config_key_by_mode, auth_mode, "api_key_secret")
  end

  defp maybe_set_defaults(content, nil, _spec), do: content

  defp maybe_set_defaults(content, selected_model, %Provider{} = spec) do
    content
    |> TomlPatch.upsert_string("defaults", "provider", spec.id)
    |> TomlPatch.upsert_string("defaults", "model", "#{spec.id}:#{selected_model}")
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

  defp prompt_yes_no?(message, default, io) do
    options =
      if default do
        [
          %{label: "Yes   [default]", value: true},
          %{label: "No", value: false}
        ]
      else
        [
          %{label: "Yes", value: true},
          %{label: "No   [default]", value: false}
        ]
      end

    case select_value(io, %{
           title: message,
           subtitle: "Use Enter to confirm.",
           options: options
         }) do
      {:ok, value} ->
        value

      :cancel ->
        default

      :fallback ->
        suffix = if default, do: " [Y/n]: ", else: " [y/N]: "

        answer =
          io.prompt.(message <> suffix)
          |> normalize_prompt_input()
          |> String.downcase()

        case answer do
          "" -> default
          "y" -> true
          "yes" -> true
          "n" -> false
          "no" -> false
          _ -> prompt_yes_no?(message, default, io)
        end
    end
  end

  defp maybe_open_url(url, io) do
    if prompt_yes_no?("Open this URL in your default browser now?", false, io) do
      case open_url_in_browser(url) do
        :ok ->
          io.info.("Opened browser.")

        {:error, reason} ->
          io.error.("Could not open browser automatically: #{inspect(reason)}")
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

  defp read_secret(prompt) do
    Mix.shell().prompt(prompt)
  end

  defp select_value(io, params) do
    case Map.get(io, :select) do
      select when is_function(select, 1) ->
        case select.(params) do
          {:ok, value} ->
            {:ok, value}

          :cancel ->
            :cancel

          {:error, reason} ->
            io.error.(
              "Interactive onboarding UI unavailable (#{format_selector_error(reason)}). Falling back to prompt mode."
            )

            :fallback

          value ->
            {:ok, value}
        end

      _ ->
        :fallback
    end
  end

  defp format_selector_error(:not_available), do: "no interactive terminal detected"
  defp format_selector_error(:no_selection), do: "selector exited before a choice was made"
  defp format_selector_error(:invalid_selector_params), do: "invalid selector parameters"
  defp format_selector_error(reason), do: inspect(reason)

  defp auth_mode_choice_label(%Provider{} = spec, :oauth) do
    spec.oauth_choice_label || "Browser sign-in (OAuth)"
  end

  defp auth_mode_choice_label(%Provider{} = spec, :api_key) do
    spec.api_key_choice_label || "Paste API key"
  end

  defp auth_mode_output_label(:oauth), do: "oauth"
  defp auth_mode_output_label(:api_key), do: "api_key"

  defp require_non_empty!(value, error_message) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: Mix.raise(error_message), else: trimmed
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

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

  defp normalize_provider_name(value) do
    value
    |> String.downcase()
    |> String.replace("_", "-")
  end
end
