defmodule Openmaru.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Openmaru.Logger.Scrubber

  @impl true
  def start(_type, _args) do
    install_log_scrubber()

    children = [
      OpenmaruWeb.Telemetry,
      Openmaru.Repo,
      {Oban, Application.fetch_env!(:openmaru, Oban)},
      {Openmaru.RateLimit, clean_period: :timer.minutes(1)},
      {DNSCluster, query: Application.get_env(:openmaru, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Openmaru.PubSub},
      # Start to serve requests, typically the last entry
      OpenmaruWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Openmaru.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # SPEC-09 §3: every handler sees scrubbed metadata and reports.
  defp install_log_scrubber do
    case :logger.add_primary_filter(:openmaru_scrubber, {&Scrubber.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenmaruWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
