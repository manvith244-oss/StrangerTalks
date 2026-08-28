defmodule StrangertalksNewWeb.Router do
  use StrangertalksNewWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StrangertalksNewWeb do
    pipe_through [:fetch_session]

    get "/", PageController, :home
    get "/matchmaking", PageController, :home
    get "/conversation", PageController, :home
    get "/conversation/ended", PageController, :home
    get "/conversation/unavailable", PageController, :home
    get "/chats", PageController, :home
    get "/chats/:conversation_id", PageController, :saved_conversation
    get "/bonds", PageController, :home
    get "/you", PageController, :home
    get "/you/memories", PageController, :home
    get "/you/reflections", PageController, :home

    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/auth/google/start", GoogleAuthController, :start
    get "/auth/google/callback", GoogleAuthController, :callback
  end

  scope "/api", StrangertalksNewWeb do
    pipe_through :api

    post "/participants", ParticipantController, :create
    get "/gifs/status", GifController, :status
    get "/gifs/search", GifController, :index
    get "/account/session", AccountController, :session
    delete "/account/session", AccountController, :logout
    delete "/account/sessions", AccountController, :logout_all
    delete "/account/google-link", AccountController, :disconnect
    get "/account/sync", AccountSyncController, :show
    put "/account/sync", AccountSyncController, :update
    delete "/account/sync", AccountSyncController, :delete

    post "/conversations/:conversation_id/companion", CompanionController, :create, log: false

    post "/conversations/:conversation_id/voice-notes/:voice_note_id",
         VoiceNoteController,
         :create,
         log: false

    get "/conversations/:conversation_id/voice-notes/:voice_note_id",
        VoiceNoteController,
        :show,
        log: false

    post "/conversations/:conversation_id/view-once/stage",
         ViewOnceMediaController,
         :stage,
         log: false

    get "/conversations/:conversation_id/view-once/:client_message_id",
        ViewOnceMediaController,
        :show,
        log: false

    get "/conversations/:conversation_id/normal-media",
        NormalMediaController,
        :index,
        log: false

    post "/conversations/:conversation_id/normal-media/:client_message_id/:kind",
         NormalMediaController,
         :create,
         log: false

    get "/conversations/:conversation_id/normal-media/:client_message_id",
        NormalMediaController,
        :show,
        log: false

    # 1T Private Save / Reflection
    get "/reflections", ReflectionController, :index
    post "/reflections", ReflectionController, :create
    post "/reflections/grants", ReflectionController, :create_grant
    put "/reflections/:id", ReflectionController, :update
    post "/reflections/:id/remove-excerpt", ReflectionController, :remove_excerpt
    delete "/reflections/:id/excerpt", ReflectionController, :remove_excerpt
    delete "/reflections/:id", ReflectionController, :delete
    post "/reflections/:id/undo", ReflectionController, :undo
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:strangertalks_new, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
