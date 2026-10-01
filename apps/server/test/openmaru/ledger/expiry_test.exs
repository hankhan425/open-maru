defmodule Openmaru.Ledger.ExpiryTest do
  use Openmaru.DataCase, async: false
  use Oban.Testing, repo: Openmaru.Repo

  import Openmaru.LedgerHelpers

  alias Openmaru.Ledger
  alias Openmaru.Ledger.ExpiryWorker

  @t0 ~U[2026-10-01 12:00:00.000000Z]

  # Funding happens a second earlier, so the first pending transfer is stamped exactly @t0.
  setup do
    set_clock(DateTime.add(@t0, -1, :second))
    a = dmnec!() |> fund!(100)
    b = account!()
    set_clock(@t0)
    %{a: a, b: b}
  end

  defp pending!(a, b, amount, timeout_secs) do
    [p] =
      create!(
        transfer(
          debit_account_id: a,
          credit_account_id: b,
          amount: amount,
          flags: [:pending],
          timeout_secs: timeout_secs,
          code: 31,
          user_data_64: 1_202_610
        )
      )

    p
  end

  defp at(seconds), do: set_clock(DateTime.add(@t0, seconds, :second))

  test "G01-T10 post after the timeout → pending_transfer_expired; the sweeper voids it once", %{
    a: a,
    b: b
  } do
    p = pending!(a, b, 40, 60)

    at(60)

    assert Ledger.create_transfers([
             transfer(flags: [:post_pending], pending_id: p.id, code: nil)
           ]) ==
             [{:error, :pending_transfer_expired}]

    assert Ledger.create_transfers([
             transfer(flags: [:void_pending], pending_id: p.id, code: nil)
           ]) ==
             [{:error, :pending_transfer_expired}]

    # Expired but not yet swept: still held.
    assert balances(a) == bal(debits_pending: 40, credits_posted: 100)

    count = transfer_count()
    assert :ok = perform_job(ExpiryWorker, %{"half" => true})
    assert transfer_count() == count + 1

    expire_id = Ledger.uuidv5("expire:#{p.id}")

    assert [
             %{
               flags: [:void_pending],
               pending_id: pending_id,
               amount: 40,
               user_data_64: -1,
               code: 31,
               debit_account_id: ^a,
               credit_account_id: ^b,
               timestamp: timestamp
             }
           ] = Ledger.lookup_transfers([expire_id])

    assert pending_id == p.id
    assert timestamp == micros(@t0) + 60_000_000
    assert balances(a) == bal(credits_posted: 100)
    assert balances(b) == bal()

    # Rerun: nothing left to expire.
    assert :ok = perform_job(ExpiryWorker, %{"half" => true})
    assert transfer_count() == count + 1
    assert {:ok, 0} = Ledger.expire_pending()

    # Swept transfers stay expired for any later resolution.
    assert Ledger.create_transfers([
             transfer(flags: [:post_pending], pending_id: p.id, code: nil)
           ]) ==
             [{:error, :pending_transfer_expired}]
  end

  test "G01-T10 before the timeout a pending transfer posts and the sweeper leaves it", %{
    a: a,
    b: b
  } do
    p = pending!(a, b, 40, 60)
    forever = pending!(a, b, 10, 0)

    at(59)
    assert {:ok, 0} = Ledger.expire_pending()
    assert balances(a) == bal(debits_pending: 50, credits_posted: 100)

    create!(transfer(flags: [:post_pending], pending_id: p.id, code: nil))

    at(10 * 365 * 24 * 3600)
    assert {:ok, 0} = Ledger.expire_pending()
    assert balances(a) == bal(debits_pending: 10, debits_posted: 40, credits_posted: 100)

    create!(transfer(flags: [:void_pending], pending_id: forever.id, code: nil))
  end

  test "G01-T10 the sweeper expires every due transfer and only those", %{a: a, b: b} do
    due = for _ <- 1..3, do: pending!(a, b, 5, 30)
    later = pending!(a, b, 5, 300)

    at(31)
    assert {:ok, 3} = Ledger.expire_pending()

    assert due
           |> Enum.map(&Ledger.uuidv5("expire:#{&1.id}"))
           |> Ledger.lookup_transfers()
           |> length() == 3

    assert Ledger.lookup_transfers([Ledger.uuidv5("expire:#{later.id}")]) == []
    assert balances(a) == bal(debits_pending: 5, credits_posted: 100)
  end

  test "G01-T10 the sweeper runs every 30 seconds: a minute cron plus a follow-up 30 s later" do
    config = Application.fetch_env!(:openmaru, Oban)
    {Oban.Plugins.Cron, cron} = List.keyfind(config[:plugins], Oban.Plugins.Cron, 0)
    assert {"* * * * *", ExpiryWorker} in cron[:crontab]

    assert :ok = perform_job(ExpiryWorker, %{})
    assert [job] = all_enqueued(worker: ExpiryWorker)
    assert job.args == %{"half" => true}
    assert job.queue == "ledger"
    assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 30, 2

    # The follow-up does not schedule another one.
    assert :ok = perform_job(ExpiryWorker, %{"half" => true})
    assert length(all_enqueued(worker: ExpiryWorker)) == 1
  end
end
