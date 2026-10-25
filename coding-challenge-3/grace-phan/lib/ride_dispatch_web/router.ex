defmodule RideDispatchWeb.Router do
  use RideDispatchWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", RideDispatchWeb do
    pipe_through :api
  end
end
