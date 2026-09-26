defmodule JaxrlDashboardWeb.HomeLive do
  use JaxrlDashboardWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Training runs
        <:subtitle>Queued, running and finished jaxrl experiments.</:subtitle>
      </.header>

      <div class="rounded-box border border-dashed border-base-300 p-10 text-center text-base-content/60">
        No runs yet. The job queue and live metrics come next.
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Runs")}
  end
end
