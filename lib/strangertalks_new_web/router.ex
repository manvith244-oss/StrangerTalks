defmodule StrangertalksNewWeb.Router do
  use StrangertalksNewWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", StrangertalksNewWeb do
    pipe_through :api

    post "/participants", ParticipantController, :create
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:strangertalks_new, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
