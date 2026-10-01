defmodule Openmaru.Ledger.ExpiryWorker do
  @moduledoc """
  Voids expired pending transfers every 30 seconds (SPEC-03 §4.3) via
  `Openmaru.Ledger.expire_pending/0`.

  Oban's cron runs it every minute (config); that run also schedules a follow-up 30 s
  later (`%{"half" => true}`), which does not schedule another.
  """

  use Oban.Worker, queue: :ledger, max_attempts: 3

  @half_minute 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    {:ok, _count} = Openmaru.Ledger.expire_pending()

    if args["half"] do
      :ok
    else
      %{"half" => true}
      |> new(schedule_in: @half_minute, unique: [period: @half_minute, fields: [:worker, :args]])
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
