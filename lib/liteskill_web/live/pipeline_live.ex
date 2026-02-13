defmodule LiteskillWeb.PipelineLive do
  @moduledoc """
  Pipeline dashboard event handlers and helpers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :html

  alias Liteskill.Rag.Pipeline
  alias Liteskill.Accounts.User

  @refresh_interval_ms 5_000

  def pipeline_assigns do
    [
      pipeline_stats: %{
        source_count: 0,
        document_count: 0,
        chunk_count: 0,
        jobs_ok: 0,
        jobs_failed: 0,
        embed_requests: 0,
        embed_errors: 0
      },
      pipeline_rates: %{},
      pipeline_chart_data: [],
      pipeline_jobs: %{jobs: [], page: 1, page_size: 20, total: 0, total_pages: 1},
      pipeline_job_search: "",
      pipeline_scope: :user,
      pipeline_is_admin: false,
      pipeline_window: :hour
    ]
  end

  def apply_pipeline_action(socket, :pipeline, _params) do
    user = socket.assigns.current_user
    is_admin = User.admin?(user)
    scope = :user

    socket
    |> Phoenix.Component.assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: [],
      pipeline_is_admin: is_admin,
      pipeline_scope: scope,
      pipeline_job_search: "",
      pipeline_window: :hour,
      page_title: "RAG Pipeline"
    )
    |> load_pipeline_data(user.id, scope)
    |> schedule_pipeline_refresh()
  end

  def handle_event("pipeline_toggle_scope", _params, socket) do
    new_scope = if socket.assigns.pipeline_scope == :user, do: :all, else: :user
    user_id = socket.assigns.current_user.id

    socket =
      socket
      |> Phoenix.Component.assign(pipeline_scope: new_scope)
      |> load_pipeline_data(user_id, new_scope)

    {:noreply, socket}
  end

  def handle_event("pipeline_search_jobs", %{"search" => search}, socket) do
    user_id = socket.assigns.current_user.id
    scope = socket.assigns.pipeline_scope

    jobs =
      Pipeline.list_jobs(user_id, scope: scope, page: 1, search: search)

    {:noreply,
     Phoenix.Component.assign(socket,
       pipeline_job_search: search,
       pipeline_jobs: jobs
     )}
  end

  def handle_event("pipeline_jobs_page", %{"page" => page}, socket) do
    {page, _} = Integer.parse(page)
    user_id = socket.assigns.current_user.id
    scope = socket.assigns.pipeline_scope
    search = socket.assigns.pipeline_job_search

    jobs =
      Pipeline.list_jobs(user_id,
        scope: scope,
        page: page,
        search: if(search == "", do: nil, else: search)
      )

    {:noreply, Phoenix.Component.assign(socket, pipeline_jobs: jobs)}
  end

  def handle_event("pipeline_select_window", %{"window" => window}, socket) do
    window = String.to_existing_atom(window)
    {:noreply, Phoenix.Component.assign(socket, pipeline_window: window)}
  end

  def handle_info(:pipeline_refresh, socket) do
    if socket.assigns.live_action == :pipeline do
      user_id = socket.assigns.current_user.id
      scope = socket.assigns.pipeline_scope

      socket =
        socket
        |> load_pipeline_data(user_id, scope)
        |> schedule_pipeline_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp load_pipeline_data(socket, user_id, scope) do
    stats = Pipeline.aggregate_stats(user_id, scope: scope)
    rates = Pipeline.windowed_rates(user_id, scope: scope)
    chart_data = Pipeline.chunks_per_source(user_id, scope: scope)
    search = socket.assigns.pipeline_job_search

    jobs =
      Pipeline.list_jobs(user_id,
        scope: scope,
        search: if(search == "", do: nil, else: search)
      )

    Phoenix.Component.assign(socket,
      pipeline_stats: stats,
      pipeline_rates: rates,
      pipeline_chart_data: chart_data,
      pipeline_jobs: jobs
    )
  end

  defp schedule_pipeline_refresh(socket) do
    Process.send_after(self(), :pipeline_refresh, @refresh_interval_ms)
    socket
  end
end
