defmodule Liteskill.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # coveralls-ignore-start
  @env Application.compile_env(:liteskill, :env)
  # coveralls-ignore-stop

  @impl true
  def start(_type, _args) do
    children =
      [
        LiteskillWeb.Telemetry,
        Liteskill.Repo,
        {DNSCluster, query: Application.get_env(:liteskill, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Liteskill.PubSub},
        {Oban, Application.fetch_env!(:liteskill, Oban)},
        # Ensure root admin account exists on boot (skip in test — sandbox not available)
        # coveralls-ignore-start
        if(@env != :test,
          do: {Task, fn -> Liteskill.Accounts.ensure_admin_user() end}
        ),
        # coveralls-ignore-stop
        # Chat projector - subscribes to event store PubSub and updates projections
        Liteskill.Chat.Projector,
        # Start to serve requests, typically the last entry
        LiteskillWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Liteskill.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiteskillWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
