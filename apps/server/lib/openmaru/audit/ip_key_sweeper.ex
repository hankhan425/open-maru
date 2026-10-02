defmodule Openmaru.Audit.IpKeySweeper do
  @moduledoc "Hourly destruction of audit IP hash keys past retention (`Openmaru.Audit.destroy_expired_ip_keys/0`, SPEC-09 §7)."

  use Oban.Worker, queue: :scheduled, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _destroyed = Openmaru.Audit.destroy_expired_ip_keys()
    :ok
  end
end
