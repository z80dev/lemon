defmodule Mix.Tasks.Lemon.ModelsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Models

  test "lists known models without credential fields" do
    output =
      capture_io(fn ->
        Models.run(["--provider", "anthropic", "--limit", "2"])
      end)

    assert output =~ "Lemon Models"
    assert output =~ "Source: ai_models"
    assert output =~ "Includes credentials: false"
    assert output =~ "Includes secret values: false"
    assert output =~ "anthropic:"
    refute output =~ "api_key"
  end

  test "emits JSON with summaries and filters" do
    output =
      capture_io(fn ->
        Models.run(["--provider", "anthropic", "--thinking", "--limit", "3", "--json"])
      end)

    decoded = Jason.decode!(output)

    assert decoded["summary"]["source"] == "ai_models"
    assert decoded["summary"]["includes_credentials"] == false
    assert decoded["summary"]["includes_secret_values"] == false
    assert decoded["summary"]["total"] <= 3
    assert decoded["summary"]["thinking_model_count"] == decoded["summary"]["total"]
    assert Enum.all?(decoded["models"], &(&1["provider"] == "anthropic"))
    assert Enum.all?(decoded["models"], &(&1["supports_thinking"] == true))
  end

  describe "--discover" do
    setup do
      {:ok, _} = Application.ensure_all_started(:lemon_ai)
      LemonAi.ModelCache.invalidate_all()
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})
      previous_key = System.get_env("LM_STUDIO_API_KEY")
      System.delete_env("LM_STUDIO_API_KEY")

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
        LemonAi.ModelCache.invalidate_all()
        if previous_key, do: System.put_env("LM_STUDIO_API_KEY", previous_key)
      end)

      :ok
    end

    test "lists models served by a preset endpoint, resolving omp aliases" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.host, conn.port, conn.request_path, conn.req_headers})
        Req.Test.json(conn, %{"data" => [%{"id" => "qwen2.5-coder-7b-instruct"}]})
      end)

      output =
        capture_io(fn ->
          Models.run([
            "--provider",
            "lm-studio",
            "--discover",
            "--base-url",
            "http://gpu-box.test:1234/v1",
            "--json"
          ])
        end)

      assert_receive {:request, "gpu-box.test", 1234, "/v1/models", headers}
      refute List.keymember?(headers, "authorization", 0)

      decoded = Jason.decode!(output)
      assert decoded["summary"]["source"] == "discovery"

      assert [%{"provider" => "lm_studio", "id" => "qwen2.5-coder-7b-instruct"}] =
               decoded["models"]
    end

    test "an unreachable endpoint fails with a discovery error" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert_raise Mix.Error, ~r/Model discovery for ollama at .* connection failed/, fn ->
        Models.run(["--provider", "ollama", "--discover", "--base-url", "http://127.0.0.1:1/v1"])
      end
    end
  end
end
