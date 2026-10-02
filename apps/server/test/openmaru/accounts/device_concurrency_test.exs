defmodule Openmaru.Accounts.DeviceConcurrencyTest do
  # Commits outside the sandbox: the polls are real concurrent transactions.
  use Openmaru.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Openmaru.Accounts.Device
  alias Openmaru.Error

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The user's PATs and decided device codes go with the user (ON DELETE CASCADE); the
  # append-only audit rows need the trigger off for the deletion only.
  defp delete_committed!(user_id) do
    id = Ecto.UUID.dump!(user_id)

    {:ok, _} =
      unboxed(fn ->
        Repo.transaction(fn ->
          Repo.query!("ALTER TABLE audit_log DISABLE TRIGGER USER")
          Repo.query!("DELETE FROM audit_log WHERE actor_id = $1", [id])
          Repo.query!("ALTER TABLE audit_log ENABLE TRIGGER USER")
          Repo.query!("DELETE FROM users WHERE id = $1", [id])
        end)
      end)

    :ok
  end

  test "C02-T07 concurrent polls of an approved code issue exactly one token" do
    {user, device_code} =
      unboxed(fn ->
        user = insert!(:user)
        {:ok, %{device_code: device_code, user_code: user_code}} = Device.start()
        :ok = Device.approve(user, user_code)
        {user, device_code}
      end)

    on_exit(fn -> delete_committed!(user.id) end)

    results =
      1..10
      |> Task.async_stream(fn _ -> unboxed(fn -> Device.poll(device_code) end) end,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, "om_pat_" <> _, _pat}] = Enum.filter(results, &match?({:ok, _, _}, &1))
    assert Enum.count(results, &match?({:error, %Error{code: :invalid_grant}}, &1)) == 9

    count =
      unboxed(fn ->
        Repo.aggregate(
          from(p in "personal_access_tokens", where: p.user_id == type(^user.id, Ecto.UUID)),
          :count
        )
      end)

    assert count == 1
  end
end
