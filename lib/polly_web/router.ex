defmodule PollyWeb.Router do
  use PollyWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers
  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PollyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  pipeline :authenticated_administrator do
    plug PollyWeb.Plugs.RequireAdministrator, permission: :export_results
  end

  scope "/", PollyWeb do
    get "/health", HealthController, :show
  end

  scope "/admin", PollyWeb do
    pipe_through [:browser, :authenticated_administrator]

    get "/polls/:poll_id/results.csv", PollResultsExportController, :show
  end

  scope "/", PollyWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      live "/admin", AdminLive, :index
      live "/admin/audit", AuditLive, :index
      live "/admin/audit/:id", AuditLive, :show
      live "/admin/members", MemberLive.Index, :index
      live "/admin/members/import", MemberLive.Import, :new
      live "/admin/polls", PollLive.Index, :index
      live "/admin/polls/new", PollLive.Form, :new
      live "/admin/polls/:id/edit", PollLive.Form, :edit
      live "/admin/polls/:id/duplicate", PollLive.Duplicate, :new
      live "/admin/polls/:id/options", PollLive.Options, :index
      live "/admin/polls/:id/electorate", PollLive.Electorate, :index
      live "/admin/polls/:id/access", PollLive.Access, :index
      live "/admin/polls/:id/results", PollLive.Results, :index
    end
  end

  scope "/admin" do
    pipe_through :browser

    oban_dashboard("/oban",
      resolver: PollyWeb.ObanWebResolver,
      logo_path: "/admin",
      as: :admin_oban_dashboard
    )
  end

  scope "/", PollyWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/polls/:poll_id/vote/:token", PollLive.Vote, :show
    auth_routes AuthController, Polly.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{PollyWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    PollyWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  PollyWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route Polly.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [PollyWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(Polly.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [PollyWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", PollyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:polly, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PollyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
