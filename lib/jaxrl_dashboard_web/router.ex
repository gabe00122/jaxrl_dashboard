defmodule JaxrlDashboardWeb.Router do
  use JaxrlDashboardWeb, :router

  import JaxrlDashboardWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JaxrlDashboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # There is intentionally no signup route: users are created on the server
  # with `mix dashboard.add_user`.
  scope "/", JaxrlDashboardWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/log-in", UserSessionController, :new
    post "/log-in", UserSessionController, :create
  end

  scope "/", JaxrlDashboardWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/log-out", UserSessionController, :delete

    live_session :require_authenticated_user,
      on_mount: [{JaxrlDashboardWeb.UserAuth, :require_authenticated}] do
      live "/", RunLive.Index, :index
      live "/runs/:name", RunLive.Show, :show
      live "/compare", CompareLive, :index
      live "/configs/new", ConfigLive.New, :new
    end

    get "/runs/:name/files/:file", RunFileController, :show
    get "/runs/:name/videos/:set/:file", RunFileController, :video
  end

  # Other scopes may use custom stacks.
  # scope "/api", JaxrlDashboardWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:jaxrl_dashboard, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: JaxrlDashboardWeb.Telemetry
    end
  end
end
