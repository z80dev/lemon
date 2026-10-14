defmodule CodingAgent.Security.SecretObfuscator.Placeholder do
  @moduledoc false
  # Placeholder format and the private per-install placeholder key.
  #
  # A placeholder is `$$<BASE>(:<hint>)$$` or `$$<FRIENDLY>_<BASE>(:<hint>)$$`.
  # BASE is 12 chars of a keyed HMAC-SHA256 of the exact secret, so a reader of
  # a transcript cannot dictionary-hash a placeholder back to its secret.

  require Logger

  @hash_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  @hash_len 12
  @max_friendly_name_len 32
  @key_file "secret-placeholder.key"
  @ephemeral_key {__MODULE__, :ephemeral_key}

  @placeholder_re ~r/\$\$(?:[A-Z0-9]+_)?[A-Z0-9]{4,}(?::[ULCM])?\$\$/
  @friendly_re ~r/^\$\$([A-Z0-9]+)_([A-Z0-9]{4,}(?::[ULCM])?)\$\$$/
  @key_re ~r/^[A-Za-z0-9_-]{43}$/

  @doc "Regex matching every placeholder-shaped token."
  def regex, do: @placeholder_re

  @doc "Path of the placeholder key file inside `agent_dir`."
  def key_path(agent_dir), do: Path.join(agent_dir, @key_file)

  @doc "Normalize a friendly name into the model-visible placeholder prefix."
  @spec sanitize_friendly_name(String.t()) :: String.t() | nil
  def sanitize_friendly_name(name) when is_binary(name) do
    case name |> sanitize_for_collision() |> binary_part_safe(@max_friendly_name_len) do
      "" -> nil
      sanitized -> sanitized
    end
  end

  @doc "Alphanumeric-only upper-cased form, used for label/secret collision checks."
  @spec sanitize_for_collision(String.t()) :: String.t()
  def sanitize_for_collision(value) do
    value |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.upcase()
  end

  @doc """
  Whether a sanitized label would leak a sanitized secret: it contains the whole
  secret, or it reaches the display cap and is the secret's visible prefix.
  """
  def label_collides_with_secret?(_label, ""), do: false

  def label_collides_with_secret?(label, sanitized_secret) do
    String.contains?(label, sanitized_secret) or
      (byte_size(label) >= @max_friendly_name_len and
         String.starts_with?(sanitized_secret, label))
  end

  @doc "Split `$$FRIENDLY_BASE(:h)$$` into `{\"FRIENDLY\", \"$$BASE(:h)$$\"}`."
  @spec split_friendly(String.t()) :: {String.t(), String.t()} | nil
  def split_friendly(token) do
    case Regex.run(@friendly_re, token, capture: :all_but_first) do
      [prefix, rest] -> {prefix, "$$" <> rest <> "$$"}
      _ -> nil
    end
  end

  @doc "12-char base36 tag from the first 64 bits of HMAC-SHA256(key, value)."
  @spec hash_base(String.t(), String.t()) :: String.t()
  def hash_base(key, value) do
    <<v::unsigned-big-64, _::binary>> = :crypto.mac(:hmac, :sha256, key, value)

    {chars, _} =
      Enum.reduce(1..@hash_len, {[], v}, fn _, {acc, n} ->
        {[Enum.at(@hash_chars, rem(n, 36)) | acc], div(n, 36)}
      end)

    chars |> Enum.reverse() |> List.to_string()
  end

  @doc "Case hint for the ASCII letters of `secret`: U, L, C, M or nil."
  @spec case_hint(String.t()) :: String.t() | nil
  def case_hint(secret) do
    secret
    |> :binary.bin_to_list()
    |> Enum.filter(&(&1 in ?A..?Z or &1 in ?a..?z))
    |> case do
      [] ->
        nil

      [first | rest] = letters ->
        cond do
          Enum.all?(letters, &(&1 in ?A..?Z)) -> "U"
          Enum.all?(letters, &(&1 in ?a..?z)) -> "L"
          first in ?A..?Z and Enum.all?(rest, &(&1 in ?a..?z)) -> "C"
          true -> "M"
        end
    end
  end

  @doc "Assemble a placeholder token."
  def build(hint, base, friendly_name) do
    prefix = if friendly_name, do: friendly_name <> "_", else: ""
    suffix = if hint, do: ":" <> hint, else: ""
    "$$" <> prefix <> base <> suffix <> "$$"
  end

  @doc """
  Read the persisted key, creating it (mode 0600) when missing. Never raises:
  an unreadable/unwritable key degrades to a process-ephemeral key with a warning.
  """
  @spec load_or_create_key(Path.t()) :: String.t()
  def load_or_create_key(path) do
    case read_key(path) do
      {:ok, key} -> key
      _ -> create_key(path)
    end
  end

  @doc "Read the persisted key without creating one."
  @spec load_existing_key(Path.t()) :: String.t() | nil
  def load_existing_key(path) do
    case read_key(path) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  defp read_key(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, raw} <- File.read(path),
         key = String.trim(raw),
         true <- Regex.match?(@key_re, key) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp create_key(path) do
    generated = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      # chmod before any key byte lands so the key is never world-readable.
      result =
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(io, generated) do
          generated
        end

      File.close(io)

      case result do
        ^generated -> generated
        error -> ephemeral_key(path, error)
      end
    else
      {:error, :eexist} ->
        # Another process won the create race; accept its key when valid.
        case read_key(path) do
          {:ok, key} -> key
          _ -> ephemeral_key(path, :invalid_existing_key)
        end

      error ->
        ephemeral_key(path, error)
    end
  end

  defp ephemeral_key(path, reason) do
    Logger.warning(
      "Could not persist secret placeholder key at #{path} (#{inspect(reason)}); " <>
        "using a process-ephemeral key"
    )

    case :persistent_term.get(@ephemeral_key, nil) do
      nil ->
        key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        :persistent_term.put(@ephemeral_key, key)
        key

      key ->
        key
    end
  end

  defp binary_part_safe(value, max) when byte_size(value) <= max, do: value
  defp binary_part_safe(value, max), do: binary_part(value, 0, max)
end
