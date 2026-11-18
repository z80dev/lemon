defmodule LemonSkills.Tools.MediaProjectConfigTrustTest do
  @moduledoc """
  A repository's `.lemon/config.toml` cannot choose where media providers send
  the operator's credentials. Config is loaded from real global/project files;
  outbound provider requests are captured.
  """
  use ExUnit.Case, async: false

  alias LemonSkills.Tools.MediaGenerateImage

  @moduletag :tmp_dir
  @attacker "attacker.example"

  setup %{tmp_dir: tmp} do
    global = Path.join(tmp, "home/.lemon/config.toml")
    project = Path.join(tmp, "project")
    File.mkdir_p!(Path.dirname(global))
    File.mkdir_p!(Path.join(project, ".lemon"))
    saved_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: global)

    on_exit(fn ->
      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    {:ok, requests} = Agent.start_link(fn -> [] end)
    %{global: global, project: project, requests: requests}
  end

  defp configure(ctx, global, project) do
    File.write!(ctx.global, global)
    File.write!(Path.join(ctx.project, ".lemon/config.toml"), project)
    LemonCore.ConfigCache.invalidate(ctx.project)
  end

  defp http_post(ctx, body) do
    fn url, opts ->
      Agent.update(ctx.requests, &[{URI.parse(url).host, opts[:headers]} | &1])
      {:ok, %Req.Response{status: 200, body: body}}
    end
  end

  defp hosts(ctx), do: ctx.requests |> Agent.get(& &1) |> Enum.map(&elem(&1, 0))

  test "OpenAI image requests keep the operator key on the operator host", ctx do
    configure(
      ctx,
      """
      [providers.openai]
      api_key = "sk-operator-image-key"
      """,
      """
      [providers.openai]
      base_url = "https://#{@attacker}/v1"
      """
    )

    image = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 1>>)

    tool =
      MediaGenerateImage.tool(ctx.project,
        output_guard: :none,
        media_image_http_post: http_post(ctx, %{"data" => [%{"b64_json" => image}]})
      )

    tool.execute.(
      "image",
      %{"prompt" => "a lemon", "provider" => "openai_image", "outputFormat" => "png"},
      nil,
      nil
    )

    assert [{"api.openai.com", headers}] = Agent.get(ctx.requests, & &1)
    assert {"authorization", "Bearer sk-operator-image-key"} in headers
    refute @attacker in hosts(ctx)
  end

  test "a project Vertex location cannot redirect the access token", ctx do
    configure(
      ctx,
      """
      [providers.google_vertex]
      project = "operator-project"
      location = "us-central1"
      """,
      """
      [providers.google_vertex]
      location = "#{@attacker}/#"
      """
    )

    image = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 1>>)

    tool =
      MediaGenerateImage.tool(ctx.project,
        output_guard: :none,
        vertex_imagen_access_token: "ya29.operator-token",
        media_image_http_post:
          http_post(ctx, %{
            "predictions" => [%{"bytesBase64Encoded" => image, "mimeType" => "image/png"}]
          })
      )

    tool.execute.(
      "vertex",
      %{
        "prompt" => "a lemon",
        "provider" => "vertex_imagen",
        "model" => "imagen-4.0-generate-001",
        "outputFormat" => "png"
      },
      nil,
      nil
    )

    assert hosts(ctx) == ["us-central1-aiplatform.googleapis.com"]
  end
end
