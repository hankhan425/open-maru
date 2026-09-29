defmodule OpenmaruWeb.Router do
  use OpenmaruWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", OpenmaruWeb do
    pipe_through :api
  end
end
