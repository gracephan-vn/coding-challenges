defmodule RideDispatch.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RideDispatchWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:ride_dispatch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RideDispatch.PubSub},
      {RideDispatch.Dispatch.StateServer,
       name: RideDispatch.Dispatch.StateServer,
       passengers: [%{id: "P001"}],
       drivers: Application.get_env(:ride_dispatch, :demo_drivers, []),
       matching_radius_km: Application.get_env(:ride_dispatch, :matching_radius_km, 2.0),
       offer_timeout_ms: Application.get_env(:ride_dispatch, :offer_timeout_ms, 30_000)},
      {RideDispatch.Dispatch.EventDispatcher,
       name: RideDispatch.Dispatch.EventDispatcher, store: RideDispatch.Dispatch.StateServer},
      {RideDispatch.Dispatch.ExpirationScheduler,
       name: RideDispatch.Dispatch.ExpirationScheduler,
       store: RideDispatch.Dispatch.StateServer,
       scan_interval_ms:
         Application.get_env(:ride_dispatch, :offer_expiration_scan_interval_ms, 1000)},
      # Start to serve requests, typically the last entry
      RideDispatchWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RideDispatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RideDispatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
