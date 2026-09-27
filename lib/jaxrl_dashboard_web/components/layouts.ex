defmodule JaxrlDashboardWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use JaxrlDashboardWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom,
    default: nil,
    values: [nil, :runs, :configs],
    doc: "the nav section the page belongs to"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/85 px-4 backdrop-blur-md sm:px-6 lg:px-8">
      <div class="mx-auto flex h-14 max-w-6xl items-center gap-1 sm:gap-6">
        <.link
          navigate={~p"/"}
          class="mr-2 flex shrink-0 items-center gap-2 text-sm font-semibold tracking-tight sm:mr-0"
        >
          <span class="grid size-7 place-items-center rounded-field bg-primary text-primary-content">
            <.icon name="hero-cpu-chip-micro" class="size-4" />
          </span>
          <span class="hidden min-[360px]:inline">rl dashboard</span>
        </.link>

        <nav :if={@current_scope} id="main-nav" class="flex items-center gap-0.5">
          <.nav_link navigate={~p"/"} active={@active == :runs}>Runs</.nav_link>
          <.nav_link navigate={~p"/configs/new"} active={@active == :configs}>
            New config
          </.nav_link>
        </nav>

        <div class="ml-auto flex items-center">
          <%= if @current_scope do %>
            <.account_menu user={@current_scope.user} />
          <% else %>
            <.theme_toggle />
          <% end %>
        </div>
      </div>
    </header>

    <main class="px-4 pt-6 pb-20 sm:px-6 sm:pt-10 lg:px-8">
      <div class="mx-auto max-w-6xl space-y-5">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "rounded-field px-2.5 py-1.5 text-sm whitespace-nowrap transition-colors duration-150",
        if(@active,
          do: "bg-base-200 font-medium text-base-content",
          else: "text-base-content/60 hover:bg-base-200/60 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :user, :map, required: true

  # Who's signed in, the theme and logging out, behind the user's initial.
  defp account_menu(assigns) do
    ~H"""
    <details
      id="account-menu"
      class="dropdown dropdown-end"
      phx-click-away={JS.remove_attribute("open", to: "#account-menu")}
    >
      <summary
        class="grid size-8 cursor-pointer list-none place-items-center rounded-full border border-base-300 bg-base-200 text-xs font-semibold uppercase transition-colors hover:border-base-content/30 [&::-webkit-details-marker]:hidden"
        aria-label="Account menu"
      >
        {String.first(@user.username)}
      </summary>
      <div class="dropdown-content z-40 mt-2 w-64 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg">
        <div class="px-2.5 pt-1.5 pb-2">
          <p class="text-xs text-base-content/60">Signed in as</p>
          <p class="truncate text-sm font-medium">{@user.username}</p>
        </div>
        <div class="my-1 h-px bg-base-300" />
        <div class="flex items-center justify-between gap-4 px-2.5 py-1.5 text-sm">
          <span class="text-base-content/80">Theme</span>
          <.theme_toggle />
        </div>
        <div class="my-1 h-px bg-base-300" />
        <.link
          href={~p"/log-out"}
          method="delete"
          id="log-out"
          class="flex items-center gap-2 rounded-field px-2.5 py-2 text-sm text-base-content/80 transition-colors hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> Log out
        </.link>
      </div>
    </details>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex w-24 shrink-0 items-center rounded-full border border-base-300 bg-base-200">
      <div class="absolute inset-y-0 left-0 w-1/3 rounded-full bg-base-100 shadow-sm ring-1 ring-base-300 transition-[left] duration-200 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />
      <button
        :for={
          {theme, icon} <- [
            system: "hero-computer-desktop-micro",
            light: "hero-sun-micro",
            dark: "hero-moon-micro"
          ]
        }
        type="button"
        class="relative flex w-1/3 cursor-pointer justify-center py-1.5 text-base-content/60 transition-colors hover:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={"#{theme} theme"}
        title={"#{String.capitalize(to_string(theme))} theme"}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end
end
