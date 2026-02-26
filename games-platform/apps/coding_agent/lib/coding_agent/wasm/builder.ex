defmodule CodingAgent.Wasm.Builder do
  @moduledoc """
  Builds and resolves the native Rust WASM sidecar runtime binary.
  """

  require Logger

  alias CodingAgent.Wasm.Config

  @type build_report :: %{
          runtime_path: String.t(),
          built?: boolean(),
          output: String.t() | nil
        }

  @spec ensure_runtime_binary(Config.t()) :: {:ok, String.t(), build_report()} | {:error, term()}
  def ensure_runtime_binary(%Config{} = wasm_config) do
    configured = wasm_config.runtime_path
    default_path = default_runtime_path()

    case configured do
      path when is_binary(path) ->
        if runtime_exists?(path) do
          {:ok, path, %{runtime_path: path, built?: false, output: nil}}
        else
          {:error, {:runtime_missing, path}}
        end

      _ ->
        cond do
          runtime_exists?(default_path) ->
            {:ok, default_path, %{runtime_path: default_path, built?: false, output: nil}}

          wasm_config.auto_build ->
            build_runtime(default_path)

          true ->
            {:error, {:runtime_missing, default_path}}
        end
    end
  end

  @spec default_runtime_path() :: String.t()
  def default_runtime_path do
    Path.join([target_dir(), "release", binary_name()])
  end

  @spec manifest_path() :: String.t()
  def manifest_path do
    Path.join([repo_root(), "native", "lemon-wasm-runtime", "Cargo.toml"])
  end

  @spec target_dir() :: String.t()
  def target_dir do
    Path.join([repo_root(), "_build", "lemon-wasm-runtime"])
  end

  @spec manual_build_command() :: String.t()
  def manual_build_command do
    "CARGO_TARGET_DIR=#{target_dir()} cargo build --release --manifest-path #{manifest_path()}"
  end

  defp runtime_exists?(path) when is_binary(path) do
    File.regular?(path)
  end

  defp build_runtime(expected_path) do
    File.mkdir_p!(target_dir())

    args = ["build", "--release", "--manifest-path", manifest_path()]

    {output, exit_code} =
      System.cmd("cargo", args,
        cd: repo_root(),
        env: [{"CARGO_TARGET_DIR", target_dir()}],
        stderr_to_stdout: true
      )

    case {exit_code, runtime_exists?(expected_path)} do
      {0, true} ->
        {:ok, expected_path, %{runtime_path: expected_path, built?: true, output: output}}

      {0, false} ->
        {:error, {:runtime_build_missing_output, expected_path, output}}

      {_code, _} ->
        {:error, {:runtime_build_failed, output}}
    end
  rescue
    error ->
      Logger.warning("WASM runtime build failed: #{Exception.message(error)}")
      {:error, {:runtime_build_exception, error}}
  end

  defp binary_name do
    case :os.type() do
      {:win32, _} -> "lemon-wasm-runtime.exe"
      _ -> "lemon-wasm-runtime"
    end
  end

  defp repo_root do
    Path.expand(Path.join(__DIR__, "../../../../../"))
  end
end
