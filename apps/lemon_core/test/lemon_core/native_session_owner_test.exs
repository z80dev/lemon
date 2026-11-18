defmodule LemonCore.NativeSessionOwnerTest do
  use ExUnit.Case, async: false

  alias LemonCore.{NativeSessionOwner, ResumeToken, Store}

  setup do
    resume = %ResumeToken{
      engine: "lemon",
      value: "native-owner-#{System.unique_integer([:positive])}"
    }

    on_exit(fn -> Store.delete(:native_session_owners, {resume.engine, resume.value}) end)
    %{resume: resume}
  end

  test "the first binding wins and is never rewritten", %{resume: resume} do
    assert {:ok, nil} = NativeSessionOwner.fetch(resume)
    refute NativeSessionOwner.owned_by?(resume, "agent:a:main")

    assert :ok = NativeSessionOwner.bind(resume, "agent:a:main")
    assert :ok = NativeSessionOwner.bind(resume, "agent:a:main")
    assert {:error, :resume_owner_conflict} = NativeSessionOwner.bind(resume, "agent:b:main")

    assert {:ok, "agent:a:main"} = NativeSessionOwner.fetch(resume)
    assert NativeSessionOwner.owned_by?(resume, "agent:a:main")
    refute NativeSessionOwner.owned_by?(resume, "agent:b:main")
    refute NativeSessionOwner.owned_by?(resume, nil)
  end
end
