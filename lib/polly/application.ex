defmodule Polly.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PollyWeb.Telemetry,
      Polly.Repo,
      {DNSCluster, query: Application.get_env(:polly, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Polly.PubSub},
      # Start a worker by calling: Polly.Worker.start_link(arg)
      # {Polly.Worker, arg},
      # Start to serve requests, typically the last entry
      PollyWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Polly.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PollyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
