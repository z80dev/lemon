defmodule LemonSkills.Tools.MediaCredentialPathsTest do
  # Mutates HOME, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias LemonSkills.Tools.{MediaAnalyzeImage, MediaTranscribeAudio}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("HOME")
    home = Path.join(tmp_dir, "home")
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(project)
    System.put_env("HOME", home)
    on_exit(fn -> System.put_env("HOME", previous) end)

    cookie = Path.join(home, ".lemon/cookie")
    File.write!(cookie, "media-cookie-secret\n")
    {:ok, project: project, cookie: cookie}
  end

  test "image and audio inputs that alias a credential are never read or uploaded", ctx do
    {:ok, posts} = Agent.start_link(fn -> 0 end)

    post = fn _url, _opts ->
      Agent.update(posts, &(&1 + 1))
      {:ok, %Req.Response{status: 200, body: %{}}}
    end

    for {name, link} <- [{"link", &File.ln_s!/2}, {"hard", &File.ln!/2}] do
      link.(ctx.cookie, Path.join(ctx.project, "#{name}.png"))
      link.(ctx.cookie, Path.join(ctx.project, "#{name}.wav"))

      image =
        MediaAnalyzeImage.tool(ctx.project,
          openai_vision_api_key: "sk-test",
          openai_vision_base_url: "https://api.openai.test/v1/",
          media_vision_http_post: post
        )

      assert {:error, message} =
               image.execute.(
                 "call-1",
                 %{"imagePath" => "#{name}.png", "provider" => "openai_vision"},
                 nil,
                 nil
               )

      assert message =~ "credential"

      audio =
        MediaTranscribeAudio.tool(ctx.project,
          openai_transcription_api_key: "sk-test",
          openai_transcription_base_url: "https://api.openai.test/v1/",
          media_transcription_http_post: post
        )

      assert {:error, message} =
               audio.execute.(
                 "call-1",
                 %{"audioPath" => "#{name}.wav", "provider" => "openai_transcribe"},
                 nil,
                 nil
               )

      assert message =~ "credential"
    end

    assert Agent.get(posts, & &1) == 0
  end
end
