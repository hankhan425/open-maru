defmodule Openmaru.Accounts.PruneWorker do
  @moduledoc "Hourly cleanup of expired auth challenges and dead sessions (`Openmaru.Accounts.prune/0`)."

  use Oban.Worker, queue: :scheduled, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _deleted = Openmaru.Accounts.prune()
    :ok
  end
end
