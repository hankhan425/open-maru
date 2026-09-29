defmodule Openmaru.ObanTest do
  use Openmaru.DataCase, async: true
  use Oban.Testing, repo: Openmaru.Repo

  defmodule ProbeWorker do
    @moduledoc false
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"pid" => pid}}) do
      pid |> Base.decode64!() |> :erlang.binary_to_term() |> send(:performed)
      :ok
    end
  end

  test "T02-T13 Oban is configured with the six queues and the Cron plugin" do
    config = Application.fetch_env!(:openmaru, Oban)

    assert config[:queues] |> Keyword.keys() |> Enum.sort() ==
             Enum.sort([:default, :ledger, :webhooks, :gateway, :runtime, :scheduled])

    assert {Oban.Plugins.Cron, cron} = List.keyfind(config[:plugins], Oban.Plugins.Cron, 0)

    # Later tasks add schedules (C01: auth cleanup); every entry must name an Oban worker.
    for {expression, worker} <- cron[:crontab] do
      assert {:ok, _} = Oban.Cron.Expression.parse(expression)
      assert Code.ensure_loaded?(worker) and function_exported?(worker, :perform, 1)
    end
  end

  test "T02-T13 jobs are enqueued but not executed automatically in tests" do
    assert Oban.config().testing == :manual

    pid = self() |> :erlang.term_to_binary() |> Base.encode64()
    {:ok, _job} = %{"pid" => pid} |> ProbeWorker.new() |> Oban.insert()

    assert_enqueued(worker: ProbeWorker, args: %{"pid" => pid})
    refute_receive :performed, 200

    assert :ok = perform_job(ProbeWorker, %{"pid" => pid})
    assert_received :performed
  end
end
