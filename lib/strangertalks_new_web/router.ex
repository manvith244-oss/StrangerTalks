defmodule StrangertalksNewWeb.Router do
  use StrangertalksNewWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StrangertalksNewWeb do
    pipe_through [:fetch_session]

    get "/", PageController, :home
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/auth/google/start", GoogleAuthController, :start
    get "/auth/google/callback", GoogleAuthController, :callback
  end

  scope "/api", StrangertalksNewWeb do
    pipe_through :api

    post "/participants", ParticipantController, :create
    get "/account/session", AccountController, :session
    delete "/account/session", AccountController, :logout
    delete "/account/sessions", AccountController, :logout_all
    delete "/account/google-link", AccountController, :disconnect

    post "/conversations/:conversation_id/voice-notes/:voice_note_id",
         VoiceNoteController,
         :create

    get "/conversations/:conversation_id/voice-notes/:voice_note_id", VoiceNoteController, :show
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:strangertalks_new, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
