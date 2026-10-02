defmodule Openmaru.Accounts.PATTest do
  use Openmaru.DataCase, async: true

  alias Openmaru.Accounts.{PAT, User}
  alias Openmaru.ClockMock

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @day 24 * 3600

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    %{user: insert!(:user)}
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp audit_rows(action) do
    Repo.all(
      from a in "audit_log",
        where: a.action == ^action,
        select: %{
          actor_kind: a.actor_kind,
          actor_id: a.actor_id,
          target_type: a.target_type,
          target_id: a.target_id,
          metadata: a.metadata
        }
    )
  end

  test "C02-T01 create returns the plaintext once and stores its hash and last4", %{user: user} do
    assert {:ok, "om_pat_" <> _ = token, pat} = PAT.create(user, %{"name" => " laptop "})

    assert pat.user_id == user.id
    assert pat.name == "laptop"
    assert pat.token_hash == :crypto.hash(:sha256, token)
    assert pat.last4 == String.slice(token, -4, 4)
    assert pat.expires_at == nil
    assert pat.inserted_at == @t0
    assert String.length(token) == String.length("om_pat_") + 43
  end

  test "C02-T01 create accepts atom keys and ttl_days", %{user: user} do
    assert {:ok, _token, pat} = PAT.create(user, %{name: "ci", ttl_days: 90})
    assert pat.expires_at == DateTime.add(@t0, 90 * @day, :second)
  end

  test "C02-T01 create and revoke are audited without the token", %{user: user} do
    {:ok, token, pat} = PAT.create(user, %{"name" => "laptop"}, %{ip: {10, 0, 0, 1}})
    :ok = PAT.revoke(user, pat.id, %{ip: {10, 0, 0, 1}})

    for action <- ["pat.created", "pat.revoked"] do
      assert [row] = audit_rows(action)
      assert row.actor_kind == "person"
      assert Ecto.UUID.cast!(row.actor_id) == user.id
      assert row.target_type == "personal_access_token"
      assert Ecto.UUID.cast!(row.target_id) == pat.id
      "om_pat_" <> secret = token
      refute inspect(row.metadata) =~ secret
    end
  end

  test "C02-T02 verify returns the user and the token record", %{user: user} do
    {:ok, token, pat} = PAT.create(user, %{"name" => "cli"})

    assert {:ok, %User{id: id}, verified} = PAT.verify(token)
    assert id == user.id
    assert verified.id == pat.id
    assert verified.last_used_at == @t0
  end

  test "C02-T02 verify refuses unknown, revoked and expired tokens with invalid_token", %{
    user: user
  } do
    {:ok, revoked, revoked_pat} = PAT.create(user, %{"name" => "r"})
    :ok = PAT.revoke(user, revoked_pat.id)
    {:ok, expired, _pat} = PAT.create(user, %{"name" => "e", "ttl_days" => 1})

    at(@day)

    for {token, reason} <- [
          {revoked, "revoked"},
          {expired, "expired"},
          {"om_pat_" <> String.duplicate("A", 43), "unknown"},
          {"om_pat_", "unknown"}
        ] do
      assert {:error, %Openmaru.Error{code: :invalid_token, details: %{reason: ^reason}}} =
               PAT.verify(token)
    end

    assert {:error, %Openmaru.Error{code: :invalid_token}} = PAT.verify(nil)
  end

  test "C02-T02 a suspended user's token is forbidden", %{user: user} do
    {:ok, token, _pat} = PAT.create(user, %{"name" => "cli"})
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [suspended_at: @t0])

    assert {:error, %Openmaru.Error{code: :forbidden, details: %{reason: "user_suspended"}}} =
             PAT.verify(token)
  end

  test "C02-T02 revoke only touches the owner's tokens", %{user: user} do
    other = insert!(:user)
    {:ok, token, pat} = PAT.create(other, %{"name" => "theirs"})

    assert {:error, %Openmaru.Error{code: :not_found}} = PAT.revoke(user, pat.id)
    assert {:error, %Openmaru.Error{code: :not_found}} = PAT.revoke(user, Ecto.UUID.generate())
    assert {:ok, _user, _pat} = PAT.verify(token)
  end

  test "C02-T04 list returns the user's live tokens, newest first", %{user: user} do
    {:ok, _token, first} = PAT.create(user, %{"name" => "first"})
    {:ok, _token, second} = PAT.create(user, %{"name" => "second"})
    {:ok, _token, revoked} = PAT.create(user, %{"name" => "revoked"})
    :ok = PAT.revoke(user, revoked.id)
    {:ok, _token, _theirs} = PAT.create(insert!(:user), %{"name" => "theirs"})

    assert user |> PAT.list() |> Enum.map(& &1.id) == [second.id, first.id]
  end
end
