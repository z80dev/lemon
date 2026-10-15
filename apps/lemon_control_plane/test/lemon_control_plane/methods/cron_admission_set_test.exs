defmodule LemonControlPlane.Methods.CronAdmissionSetTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.CronAdmissionSet
  alias LemonCore.Secrets

  setup do
    previous_secrets = Application.fetch_env(:lemon_core, Secrets)
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    key_env = "LEMON_CRON_ADMISSION_RPC_TEST_KEY_" <> suffix
    System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: key_env)
    routine_id = "admission-routine-" <> suffix

    secret_name =
      "cron_admission_" <> Base.encode16(:crypto.hash(:sha256, routine_id), case: :lower)

    on_exit(fn ->
      Secrets.delete(secret_name)

      case previous_secrets do
        {:ok, config} -> Application.put_env(:lemon_core, Secrets, config)
        :error -> Application.delete_env(:lemon_core, Secrets)
      end

      System.delete_env(key_env)
    end)

    {:ok, routine_id: routine_id}
  end

  test "provisions and rotates a private encrypted token without returning its value", ctx do
    token = "private-admission-token-#{ctx.routine_id}"

    assert {:ok, %{"secretName" => secret_name, "set" => true} = response} =
             CronAdmissionSet.handle(%{"routineId" => ctx.routine_id, "token" => token}, %{})

    refute Jason.encode!(response) =~ token
    assert {:ok, ^token} = Secrets.get(secret_name)

    assert {:ok, %{"secretName" => ^secret_name, "set" => true}} =
             CronAdmissionSet.handle(
               %{"routineId" => ctx.routine_id, "token" => "rotated-private-token"},
               %{}
             )

    assert {:ok, "rotated-private-token"} = Secrets.get(secret_name)
  end

  test "invalid requests return bounded errors without echoing credentials", ctx do
    token = "do-not-return-this\ninvalid-header"

    for params <- [
          %{"routineId" => ctx.routine_id, "token" => token},
          %{"routineId" => ctx.routine_id, "token" => ""},
          %{"routineId" => "", "token" => "private-token"},
          %{"routineId" => ctx.routine_id},
          nil
        ] do
      assert {:error, {:invalid_request, message, nil}} = CronAdmissionSet.handle(params, %{})
      refute message =~ "do-not-return-this"
      refute message =~ "private-token"
    end
  end
end
