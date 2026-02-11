defmodule LiteskillWeb.ChatLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias Liteskill.Chat.ToolCall
  alias Liteskill.LLM.StreamHandler
  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient
  alias Liteskill.Repo
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.ProfileLive

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(
       conversations: conversations,
       conversation: nil,
       messages: [],
       form: to_form(%{"content" => ""}, as: :message),
       streaming: false,
       stream_content: "",
       mcp_servers: [],
       show_mcp_modal: false,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         ),
       editing_mcp: nil,
       # Tool picker state
       available_tools: [],
       selected_server_ids: MapSet.new(),
       show_tool_picker: false,
       auto_confirm_tools: true,
       pending_tool_calls: [],
       tools_loading: false,
       stream_task_pid: nil,
       inspecting_server: nil,
       inspecting_tools: [],
       inspecting_tools_loading: false,
       sidebar_open: true,
       confirm_delete_id: nil,
       data_sources: [],
       current_source: nil,
       source_documents: %{documents: [], page: 1, page_size: 20, total: 0, total_pages: 1},
       source_search: "",
       wiki_document: nil,
       wiki_tree: [],
       wiki_sidebar_tree: [],
       wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page),
       show_wiki_form: false,
       wiki_editing: nil,
       wiki_parent_id: nil,
       wiki_space: nil,
       reports: [],
       report: nil,
       report_markdown: "",
       section_tree: [],
       report_comments: [],
       editing_section_id: nil,
       report_mode: :view,
       # RAG query
       show_rag_query: false,
       rag_query_loading: false,
       rag_query_results: [],
       rag_query_collections: [],
       rag_query_error: nil,
       show_sources_sidebar: false,
       sidebar_sources: [],
       show_source_modal: false,
       source_modal_data: %{},
       stream_error: nil,
       # Wiki export modal
       show_wiki_export_modal: false,
       wiki_export_title: "",
       wiki_export_parent_id: nil,
       wiki_export_tree: []
     )
     |> assign(ProfileLive.profile_assigns()), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> push_event("nav", %{})
     |> push_accent_color()
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp push_accent_color(socket) do
    color = Liteskill.Accounts.User.accent_color(socket.assigns.current_user)
    push_event(socket, "set-accent", %{color: color})
  end

  defp apply_action(socket, action, _params)
       when action in [:info, :password, :admin_servers, :admin_users, :admin_groups] do
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: []
    )
    |> ProfileLive.apply_profile_action(action, socket.assigns.current_user)
  end

  defp apply_action(socket, :index, _params) do
    # Unsubscribe from previous conversation if any
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: [],
      page_title: "Liteskill"
    )
  end

  defp apply_action(socket, :mcp_servers, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      mcp_servers: servers,
      show_mcp_modal: false,
      editing_mcp: nil,
      pending_tool_calls: [],
      wiki_sidebar_tree: [],
      page_title: "MCP Servers"
    )
  end

  defp apply_action(socket, :sources, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    sources = Liteskill.DataSources.list_sources(user_id)

    sources =
      Enum.map(sources, fn source ->
        source_ref =
          if is_struct(source, Liteskill.DataSources.Source), do: source.id, else: source.id

        Map.put(source, :document_count, Liteskill.DataSources.document_count(source_ref))
      end)

    rag_collections = Liteskill.Rag.list_collections(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      data_sources: sources,
      wiki_sidebar_tree: [],
      rag_query_collections: rag_collections,
      show_rag_query: false,
      rag_query_results: [],
      rag_query_loading: false,
      rag_query_error: nil,
      page_title: "Data Sources"
    )
  end

  defp apply_action(socket, :wiki, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id

    result =
      Liteskill.DataSources.list_documents_paginated("builtin:wiki", user_id,
        page: 1,
        search: nil,
        parent_id: nil
      )

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      current_source: get_wiki_source(),
      source_documents: result,
      source_search: "",
      wiki_sidebar_tree: [],
      wiki_space: nil,
      page_title: "Wiki"
    )
  end

  defp apply_action(socket, :wiki_page_show, %{"document_id" => doc_id}) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.get_document(doc_id, user_id) do
      {:ok, doc} ->
        space =
          if is_nil(doc.parent_document_id) do
            doc
          else
            case Liteskill.DataSources.find_root_ancestor(doc.id, user_id) do
              {:ok, root} -> root
              _ -> nil
            end
          end

        space_children_tree =
          if space do
            Liteskill.DataSources.space_tree("builtin:wiki", space.id, user_id)
          else
            []
          end

        socket
        |> assign(
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          current_source: get_wiki_source(),
          wiki_document: doc,
          wiki_tree: space_children_tree,
          wiki_sidebar_tree: space_children_tree,
          wiki_space: space,
          show_wiki_form: false,
          wiki_editing: nil,
          wiki_parent_id: nil,
          page_title: doc.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Page not found")
        |> push_navigate(to: ~p"/wiki")
    end
  end

  defp apply_action(socket, :source_show, %{"source_id" => source_url_id}) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    source_id = source_id_from_url(source_url_id)

    case Liteskill.DataSources.get_source(source_id, user_id) do
      {:ok, source} ->
        source_ref = source.id
        search = socket.assigns.source_search

        result =
          Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
            page: 1,
            search: if(search == "", do: nil, else: search),
            parent_id: nil
          )

        socket
        |> assign(
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          current_source: source,
          source_documents: result,
          source_search: "",
          wiki_sidebar_tree: [],
          page_title: source.name
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Source not found")
        |> push_navigate(to: ~p"/sources")
    end
  end

  defp apply_action(socket, :reports, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    reports = Liteskill.Reports.list_reports(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      reports: reports,
      wiki_sidebar_tree: [],
      page_title: "Reports"
    )
  end

  defp apply_action(socket, :report_show, %{"report_id" => report_id}) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report_id, user_id) do
      {:ok, report} ->
        markdown = Liteskill.Reports.render_markdown(report, include_comments: false)
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report_id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        socket
        |> assign(
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          report: report,
          report_markdown: markdown,
          section_tree: section_tree,
          report_comments: report_comments,
          editing_section_id: nil,
          report_mode: :view,
          wiki_sidebar_tree: [],
          page_title: report.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Report not found")
        |> push_navigate(to: ~p"/reports")
    end
  end

  defp apply_action(socket, :show, %{"conversation_id" => conversation_id}) do
    user_id = socket.assigns.current_user.id

    # Unsubscribe from previous conversation
    maybe_unsubscribe(socket)

    case Chat.get_conversation(conversation_id, user_id) do
      {:ok, conversation} ->
        # Subscribe to PubSub for real-time updates
        topic = "event_store:#{conversation.stream_id}"
        Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

        streaming = conversation.status == "streaming"
        pending = if streaming, do: load_pending_tool_calls(conversation.messages), else: []

        socket
        |> assign(
          conversation: conversation,
          messages: conversation.messages,
          streaming: streaming,
          stream_content: "",
          pending_tool_calls: pending,
          wiki_sidebar_tree: [],
          page_title: conversation.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Conversation not found")
        |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative">
      <%!-- Sidebar --%>
      <aside
        id="sidebar"
        phx-hook="SidebarNav"
        class={[
          "flex-shrink-0 bg-base-200 flex flex-col border-r border-base-300 transition-all duration-200 overflow-hidden",
          if(@sidebar_open,
            do: "w-64 max-sm:fixed max-sm:inset-0 max-sm:w-full max-sm:z-40",
            else: "w-0 border-r-0"
          )
        ]}
      >
        <div class="flex items-center justify-between p-3 border-b border-base-300 min-w-64">
          <img src={~p"/images/logo.svg"} class="size-7" />
          <div class="flex items-center gap-1">
            <Layouts.theme_toggle />
            <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
              <.icon name="hero-arrow-left-end-on-rectangle-micro" class="size-5" />
            </button>
          </div>
        </div>

        <div class="p-3 min-w-64">
          <button
            phx-click="new_conversation"
            class="btn btn-neutral btn-sm w-full gap-2"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New Chat
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto px-2 space-y-1 pb-4 min-w-64">
          <ChatComponents.conversation_item
            :for={conv <- @conversations}
            conversation={conv}
            active={@conversation && @conversation.id == conv.id}
          />
          <p
            :if={@conversations == []}
            class="text-xs text-base-content/50 text-center py-4"
          >
            No conversations yet
          </p>
        </nav>

        <%= if @wiki_sidebar_tree != [] && @live_action == :wiki_page_show && @wiki_space do %>
          <div class="px-2 pb-2 border-t border-base-300 min-w-64 overflow-y-auto max-h-64">
            <div class="py-2 px-1">
              <.link
                navigate={~p"/wiki/#{@wiki_space.id}"}
                class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2 hover:text-primary transition-colors block truncate"
              >
                {@wiki_space.title}
              </.link>
              <ChatComponents.wiki_tree_sidebar
                tree={@wiki_sidebar_tree}
                active_doc_id={if @wiki_document, do: @wiki_document.id, else: nil}
              />
            </div>
          </div>
        <% end %>

        <div class="p-2 border-t border-base-300 min-w-64">
          <.link
            navigate={~p"/wiki"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action in [:wiki, :wiki_page_show],
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-book-open-micro" class="size-4" /> Wiki
          </.link>
          <.link
            navigate={~p"/sources"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action in [:sources, :source_show],
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-circle-stack-micro" class="size-4" /> Data Sources
          </.link>
          <.link
            navigate={~p"/mcp"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action == :mcp_servers,
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-server-stack-micro" class="size-4" /> MCP Servers
          </.link>
          <.link
            navigate={~p"/reports"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action in [:reports, :report_show],
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-document-text-micro" class="size-4" /> Reports
          </.link>
        </div>

        <div class="p-3 border-t border-base-300 min-w-64">
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/profile"}
              class={[
                "flex-1 truncate text-sm hover:text-base-content",
                if(ProfileLive.profile_action?(@live_action),
                  do: "text-primary font-medium",
                  else: "text-base-content/70"
                )
              ]}
            >
              {@current_user.email}
            </.link>
            <.link href={~p"/auth/logout"} method="delete" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>

      <%!-- Main Area --%>
      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :sources do %>
          <%!-- Data Sources --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-lg font-semibold">Data Sources</h1>
              </div>
              <button phx-click="open_rag_query" class="btn btn-ghost btn-sm gap-1">
                <.icon name="hero-magnifying-glass-micro" class="size-4" /> RAG Query
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@data_sources != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.source_card
                :for={source <- @data_sources}
                source={source}
              />
            </div>
            <p
              :if={@data_sources == []}
              class="text-base-content/50 text-center py-12"
            >
              No data sources available.
            </p>
          </div>

          <ChatComponents.rag_query_modal
            show={@show_rag_query}
            collections={@rag_query_collections}
            results={@rag_query_results}
            loading={@rag_query_loading}
            error={@rag_query_error}
          />
        <% end %>
        <%= if @live_action == :source_show && @current_source do %>
          <%!-- Source Documents --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link navigate={~p"/sources"} class="btn btn-ghost btn-xs">
                  <.icon name="hero-arrow-left-micro" class="size-4" />
                </.link>
                <h1 class="text-lg font-semibold">{@current_source.name}</h1>
                <span
                  :if={Map.get(@current_source, :builtin, false)}
                  class="badge badge-sm badge-primary"
                >
                  built-in
                </span>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4 max-w-3xl mx-auto w-full">
            <ChatComponents.document_list
              source={@current_source}
              result={@source_documents}
              search={@source_search}
            />
          </div>
        <% end %>
        <%= if @live_action == :wiki do %>
          <%!-- Wiki Home — Spaces --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-lg font-semibold">Wiki</h1>
              </div>
              <button phx-click="show_wiki_form" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-plus-micro" class="size-4" /> New Space
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4 max-w-4xl mx-auto w-full">
            <div
              :if={@source_documents.documents != []}
              class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.space_card
                :for={space <- @source_documents.documents}
                space={space}
              />
            </div>
            <p
              :if={@source_documents.documents == []}
              class="text-base-content/50 text-center py-12 text-sm"
            >
              No spaces yet. Create your first space to get started.
            </p>

            <div :if={@source_documents.total_pages > 1} class="flex justify-center gap-1 pt-4">
              <button
                :if={@source_documents.page > 1}
                phx-click="source_page"
                phx-value-page={@source_documents.page - 1}
                class="btn btn-ghost btn-xs"
              >
                Previous
              </button>
              <span class="btn btn-ghost btn-xs no-animation">
                {@source_documents.page} / {@source_documents.total_pages}
              </span>
              <button
                :if={@source_documents.page < @source_documents.total_pages}
                phx-click="source_page"
                phx-value-page={@source_documents.page + 1}
                class="btn btn-ghost btn-xs"
              >
                Next
              </button>
            </div>
          </div>

          <ChatComponents.modal
            id="wiki-form-modal"
            title="New Space"
            show={@show_wiki_form}
            on_close="close_wiki_form"
          >
            <.form for={@wiki_form} phx-submit="create_wiki_page" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Space Name *</span></label>
                <input
                  type="text"
                  name="wiki_page[title]"
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Description (Markdown)</span></label>
                <textarea
                  name="wiki_page[content]"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  rows="6"
                >{Phoenix.HTML.Form.input_value(@wiki_form, :content)}</textarea>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Create Space</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :wiki_page_show && @wiki_document do %>
          <%!-- Wiki Page Detail --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link
                  navigate={
                    if is_nil(@wiki_document.parent_document_id),
                      do: ~p"/wiki",
                      else: ~p"/wiki/#{@wiki_document.parent_document_id}"
                  }
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-left-micro" class="size-4" />
                </.link>
                <h1 class="text-lg font-semibold truncate">{@wiki_document.title}</h1>
              </div>
              <div :if={!@wiki_editing} class="flex gap-1">
                <button phx-click="edit_wiki_page" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                </button>
                <button
                  phx-click="show_wiki_form"
                  phx-value-parent-id={@wiki_document.id}
                  class="btn btn-ghost btn-sm gap-1"
                >
                  <.icon name="hero-plus-micro" class="size-4" /> Add Child
                </button>
                <button
                  phx-click="delete_wiki_page"
                  data-confirm="Delete this page and all children?"
                  class="btn btn-ghost btn-sm text-error gap-1"
                >
                  <.icon name="hero-trash-micro" class="size-4" /> Delete
                </button>
              </div>
            </div>
          </header>

          <%= if @wiki_editing do %>
            <div class="flex-1 overflow-y-auto px-6 py-6 max-w-3xl mx-auto w-full">
              <.form for={@wiki_form} phx-submit="update_wiki_page" class="space-y-4">
                <div class="form-control">
                  <input
                    type="text"
                    name="wiki_page[title]"
                    value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                    class="input input-bordered w-full text-lg font-semibold"
                    required
                  />
                </div>
                <input
                  type="hidden"
                  name="wiki_page[content]"
                  data-editor-content
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                />
                <div
                  id="wiki-editor"
                  phx-hook="WikiEditor"
                  phx-update="ignore"
                  data-content={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                  class="border border-base-300 rounded-lg overflow-hidden"
                >
                  <div data-editor-target class="min-h-[300px]"></div>
                </div>
                <div class="flex justify-end gap-2 pt-2">
                  <button
                    type="button"
                    phx-click="cancel_wiki_edit"
                    class="btn btn-ghost btn-sm"
                  >
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm">Save</button>
                </div>
              </.form>
            </div>
          <% else %>
            <div class="flex-1 overflow-y-auto px-6 py-6 max-w-3xl mx-auto w-full space-y-6">
              <div
                :if={@wiki_document.content && @wiki_document.content != ""}
                id="wiki-content"
                phx-hook="CopyCode"
                class="prose prose-sm max-w-none"
              >
                {LiteskillWeb.Markdown.render(@wiki_document.content)}
              </div>
              <p
                :if={!@wiki_document.content || @wiki_document.content == ""}
                class="text-base-content/50 text-center py-8"
              >
                This page has no content yet. Click "Edit" to add some.
              </p>

              <ChatComponents.wiki_children
                source={@current_source}
                document={@wiki_document}
                tree={@wiki_tree}
              />
            </div>
          <% end %>

          <ChatComponents.modal
            id="wiki-page-modal"
            title="New Child Page"
            show={@show_wiki_form}
            on_close="close_wiki_form"
          >
            <.form for={@wiki_form} phx-submit="create_wiki_page" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Title *</span></label>
                <input
                  type="text"
                  name="wiki_page[title]"
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Content (Markdown)</span></label>
                <input
                  type="hidden"
                  name="wiki_page[content]"
                  data-editor-content
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                />
                <div
                  id="wiki-child-editor"
                  phx-hook="WikiEditor"
                  phx-update="ignore"
                  data-content={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                  class="border border-base-300 rounded-lg overflow-hidden"
                >
                  <div data-editor-target class="min-h-[200px]"></div>
                </div>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Create</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :mcp_servers do %>
          <%!-- MCP Servers --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-lg font-semibold">MCP Servers</h1>
              </div>
              <button phx-click="show_add_mcp" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-plus-micro" class="size-4" /> Add Server
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@mcp_servers != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.mcp_server_card
                :for={server <- @mcp_servers}
                server={server}
                owned={server.user_id == @current_user.id}
              />
            </div>
            <p
              :if={@mcp_servers == []}
              class="text-base-content/50 text-center py-12"
            >
              No MCP servers configured yet. Click "Add Server" to get started.
            </p>
          </div>

          <ChatComponents.modal
            id="mcp-modal"
            title={if @editing_mcp, do: "Edit Server", else: "Add Server"}
            show={@show_mcp_modal}
            on_close="close_mcp_modal"
          >
            <.form for={@mcp_form} phx-submit="save_mcp" class="space-y-4">
              <input :if={@editing_mcp} type="hidden" name="mcp_server[id]" value={@editing_mcp.id} />
              <div class="form-control">
                <label class="label"><span class="label-text">Name *</span></label>
                <input
                  type="text"
                  name="mcp_server[name]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :name)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">URL *</span></label>
                <input
                  type="url"
                  name="mcp_server[url]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :url)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">API Key</span></label>
                <input
                  type="password"
                  name="mcp_server[api_key]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :api_key)}
                  class="input input-bordered w-full"
                  autocomplete="off"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="mcp_server[description]"
                  class="textarea textarea-bordered w-full"
                  rows="2"
                >{Phoenix.HTML.Form.input_value(@mcp_form, :description)}</textarea>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Custom Headers (JSON)</span></label>
                <textarea
                  name="mcp_server[headers]"
                  class="textarea textarea-bordered w-full font-mono text-xs"
                  rows="3"
                  placeholder="{}"
                >{Phoenix.HTML.Form.input_value(@mcp_form, :headers)}</textarea>
              </div>
              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="hidden"
                    name="mcp_server[global]"
                    value="false"
                  />
                  <input
                    type="checkbox"
                    name="mcp_server[global]"
                    value="true"
                    checked={
                      Phoenix.HTML.Form.input_value(@mcp_form, :global) == true ||
                        Phoenix.HTML.Form.input_value(@mcp_form, :global) == "true"
                    }
                    class="checkbox checkbox-sm"
                  />
                  <span class="label-text">Share globally with all users</span>
                </label>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_mcp_modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {if @editing_mcp, do: "Update", else: "Create"}
                </button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :reports do %>
          <%!-- Reports --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-lg font-semibold">Reports</h1>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@reports != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.report_card
                :for={report <- @reports}
                report={report}
                owned={report.user_id == @current_user.id}
              />
            </div>
            <p
              :if={@reports == []}
              class="text-base-content/50 text-center py-12"
            >
              No reports yet. Use the Reports tools in a conversation to create one.
            </p>
          </div>
        <% end %>
        <%= if @live_action == :report_show do %>
          <%!-- Report Detail --%>
          <header
            id="report-detail"
            phx-hook="DownloadMarkdown"
            class="px-4 py-3 border-b border-base-300 flex-shrink-0"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link navigate={~p"/reports"} class="btn btn-ghost btn-sm btn-circle">
                  <.icon name="hero-arrow-left-micro" class="size-5" />
                </.link>
                <h1 class="text-lg font-semibold truncate">{@report && @report.title}</h1>
              </div>
              <div class="flex flex-wrap gap-1">
                <%= if @report_mode == :view do %>
                  <button phx-click="report_edit_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                  </button>
                <% else %>
                  <button phx-click="address_comments" class="btn btn-primary btn-sm gap-1">
                    <.icon name="hero-chat-bubble-left-right-micro" class="size-4" /> Address Comments
                  </button>
                  <button phx-click="report_view_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-eye-micro" class="size-4" /> View
                  </button>
                <% end %>
                <button phx-click="export_report" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Export
                </button>
                <button phx-click="open_wiki_export_modal" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-book-open-micro" class="size-4" /> Export to Wiki
                </button>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto px-6 py-6 space-y-6">
            <%= if @report_mode == :view do %>
              <%!-- View mode: clean markdown rendering --%>
              <div
                :if={@report_markdown != ""}
                id="report-markdown"
                phx-hook="CopyCode"
                class="prose prose-sm max-w-none"
              >
                {LiteskillWeb.Markdown.render(@report_markdown)}
              </div>
              <p
                :if={@report_markdown == ""}
                class="text-base-content/50 text-center py-12"
              >
                This report has no content yet. Use the Reports tools in a conversation to add content.
              </p>
            <% else %>
              <%!-- Edit mode: section tree with comments and inline editing --%>
              <div :if={@report_comments != []} class="space-y-2">
                <h3 class="text-sm font-semibold text-base-content/70">Report Comments</h3>
                <ChatComponents.section_comment :for={c <- @report_comments} comment={c} />
              </div>

              <form phx-submit="add_report_comment" class="flex gap-2">
                <input
                  type="text"
                  name="body"
                  placeholder="Add a report comment..."
                  class="input input-bordered input-sm flex-1"
                />
                <button type="submit" class="btn btn-sm btn-ghost">Comment</button>
              </form>

              <div :if={@section_tree != []} class="space-y-4">
                <ChatComponents.section_node
                  :for={node <- @section_tree}
                  node={node}
                  depth={1}
                  editing_section_id={@editing_section_id}
                />
              </div>

              <p
                :if={@section_tree == [] && @report_comments == []}
                class="text-base-content/50 text-center py-12"
              >
                This report has no sections yet. Use the Reports tools in a conversation to add content.
              </p>
            <% end %>
          </div>

          <ChatComponents.modal
            id="wiki-export-modal"
            title="Export to Wiki"
            show={@show_wiki_export_modal}
            on_close="close_wiki_export_modal"
          >
            <.form for={%{}} phx-submit="confirm_wiki_export" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Page Title</span></label>
                <input
                  type="text"
                  name="title"
                  value={@wiki_export_title}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Location</span></label>
                <select name="parent_id" class="select select-bordered w-full" required>
                  <option value="" disabled selected>Select a space...</option>
                  <%= for node <- @wiki_export_tree do %>
                    <ChatComponents.wiki_parent_option
                      node={node}
                      depth={0}
                      selected={@wiki_export_parent_id}
                    />
                  <% end %>
                </select>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_export_modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Export</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if ProfileLive.profile_action?(@live_action) do %>
          <ProfileLive.profile
            live_action={@live_action}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            password_form={@password_form}
            password_error={@password_error}
            password_success={@password_success}
            profile_users={@profile_users}
            profile_groups={@profile_groups}
            group_detail={@group_detail}
            group_members={@group_members}
          />
        <% end %>
        <%= if @live_action not in [:sources, :source_show, :wiki, :wiki_page_show, :mcp_servers, :reports, :report_show] and not ProfileLive.profile_action?(@live_action) do %>
          <%= if @conversation do %>
            <%!-- Active conversation --%>
            <div class="flex flex-1 min-w-0 overflow-hidden">
              <div class="flex-1 flex flex-col min-w-0">
                <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
                  <div class="flex items-center gap-2">
                    <button
                      :if={!@sidebar_open}
                      phx-click="toggle_sidebar"
                      class="btn btn-circle btn-ghost btn-sm"
                    >
                      <.icon name="hero-bars-3-micro" class="size-5" />
                    </button>
                    <h1 class="text-lg font-semibold truncate">{@conversation.title}</h1>
                  </div>
                </header>

                <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-4">
                  <%= for msg <- @messages do %>
                    <ChatComponents.message_bubble
                      :if={msg.content && msg.content != ""}
                      message={msg}
                    />
                    <ChatComponents.sources_button message={msg} />
                    <%!-- Tool calls for completed messages (inline) --%>
                    <%= if msg.role == "assistant" && msg.stop_reason == "tool_use" do %>
                      <%= for tc <- tool_calls_for_message(msg) do %>
                        <ChatComponents.tool_call_display
                          tool_call={tc}
                          show_actions={!@auto_confirm_tools && tc.status == "started"}
                        />
                      <% end %>
                    <% end %>
                    <ChatComponents.stream_error
                      :if={msg.status == "failed" && msg == List.last(@messages)}
                      error={
                        %{
                          title: "The AI service was unavailable",
                          detail: "The response failed to generate. Click retry to try again."
                        }
                      }
                    />
                  <% end %>
                  <div :if={@streaming && @stream_content != ""} class="mb-4 text-base-content">
                    <div id="streaming-prose" phx-hook="CopyCode" class="prose prose-sm max-w-none">
                      {LiteskillWeb.Markdown.render_streaming(@stream_content)}
                    </div>
                  </div>
                  <ChatComponents.streaming_indicator :if={@streaming && @stream_content == ""} />
                  <%!-- Pending tool calls from streaming message (rendered from socket state, not DB) --%>
                  <%= for tc <- @pending_tool_calls do %>
                    <ChatComponents.tool_call_display
                      tool_call={tc}
                      show_actions={!@auto_confirm_tools && tc.status == "started"}
                    />
                  <% end %>
                  <ChatComponents.stream_error :if={@stream_error} error={@stream_error} />
                </div>

                <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
                  <ChatComponents.selected_server_badges
                    available_tools={@available_tools}
                    selected_server_ids={@selected_server_ids}
                  />
                  <.form for={@form} phx-submit="send_message" class="flex gap-2 items-center">
                    <ChatComponents.server_picker
                      available_tools={@available_tools}
                      selected_server_ids={@selected_server_ids}
                      show={@show_tool_picker}
                      auto_confirm={@auto_confirm_tools}
                      tools_loading={@tools_loading}
                    />
                    <div class="flex-1">
                      <textarea
                        id="message-input"
                        name="message[content]"
                        phx-hook="TextareaAutoResize"
                        placeholder="Type a message..."
                        rows="1"
                        class="textarea textarea-bordered w-full resize-none min-h-[2.5rem] max-h-40"
                        disabled={@streaming}
                      >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                    </div>
                    <button
                      :if={!@streaming}
                      type="submit"
                      class="btn btn-primary btn-sm"
                    >
                      <.icon name="hero-paper-airplane-micro" class="size-4" />
                    </button>
                    <button
                      :if={@streaming}
                      type="button"
                      phx-click="cancel_stream"
                      class="btn btn-error btn-sm"
                    >
                      <.icon name="hero-stop-micro" class="size-4" />
                    </button>
                  </.form>
                </div>
              </div>
              <ChatComponents.sources_sidebar
                show={@show_sources_sidebar}
                sources={@sidebar_sources}
              />
            </div>
          <% else %>
            <%!-- New conversation prompt --%>
            <div :if={!@sidebar_open} class="px-4 pt-3">
              <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
                <.icon name="hero-bars-3-micro" class="size-5" />
              </button>
            </div>
            <div class="flex-1 flex items-center justify-center px-4">
              <div class="w-full max-w-xl text-center">
                <h1 class="text-3xl font-bold mb-8 text-base-content">
                  What can I help you with?
                </h1>
                <ChatComponents.selected_server_badges
                  available_tools={@available_tools}
                  selected_server_ids={@selected_server_ids}
                />
                <.form for={@form} phx-submit="send_message" class="flex gap-2 items-center">
                  <ChatComponents.server_picker
                    available_tools={@available_tools}
                    selected_server_ids={@selected_server_ids}
                    show={@show_tool_picker}
                    auto_confirm={@auto_confirm_tools}
                    tools_loading={@tools_loading}
                  />
                  <div class="flex-1">
                    <textarea
                      id="message-input"
                      name="message[content]"
                      phx-hook="TextareaAutoResize"
                      placeholder="Type a message..."
                      rows="1"
                      class="textarea textarea-bordered w-full resize-none min-h-[2.5rem] max-h-40"
                    />
                  </div>
                  <button type="submit" class="btn btn-primary btn-sm">
                    <.icon name="hero-paper-airplane-micro" class="size-4" />
                  </button>
                </.form>
              </div>
            </div>
          <% end %>
        <% end %>
      </main>

      <ChatComponents.modal
        id="tools-modal"
        title={if @inspecting_server, do: "#{@inspecting_server.name} — Tools", else: "Tools"}
        show={@inspecting_server != nil}
        on_close="close_tools_modal"
      >
        <div :if={@inspecting_tools_loading} class="text-center py-8 text-base-content/50">
          Loading tools...
        </div>
        <div
          :if={!@inspecting_tools_loading && @inspecting_tools == []}
          class="text-center py-8 text-base-content/50"
        >
          No tools found on this server.
        </div>
        <div :if={!@inspecting_tools_loading && @inspecting_tools != []} class="space-y-3">
          <ChatComponents.tool_detail :for={tool <- @inspecting_tools} tool={tool} />
        </div>
      </ChatComponents.modal>

      <ChatComponents.source_detail_modal
        show={@show_source_modal}
        source={@source_modal_data}
      />

      <ChatComponents.confirm_modal
        show={@confirm_delete_id != nil}
        title="Archive conversation"
        message="Are you sure you want to archive this conversation?"
        confirm_event="delete_conversation"
        cancel_event="cancel_delete_conversation"
      />
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("close_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: false)}
  end

  @impl true
  def handle_event("source_search", %{"search" => search}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id

    result =
      Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
        page: 1,
        search: if(search == "", do: nil, else: search),
        parent_id: nil
      )

    {:noreply, assign(socket, source_search: search, source_documents: result)}
  end

  @impl true
  def handle_event("source_page", %{"page" => page}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id
    search = socket.assigns.source_search

    result =
      Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
        page: String.to_integer(page),
        search: if(search == "", do: nil, else: search),
        parent_id: nil
      )

    {:noreply, assign(socket, source_documents: result)}
  end

  # --- RAG Query Events ---

  @impl true
  def handle_event("open_rag_query", _params, socket) do
    {:noreply,
     assign(socket,
       show_rag_query: true,
       rag_query_results: [],
       rag_query_error: nil,
       rag_query_loading: false
     )}
  end

  @impl true
  def handle_event("close_rag_query", _params, socket) do
    {:noreply,
     assign(socket,
       show_rag_query: false,
       rag_query_results: [],
       rag_query_error: nil,
       rag_query_loading: false
     )}
  end

  @impl true
  def handle_event("rag_search", %{"collection_id" => coll_id, "query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, rag_query_error: "Please enter a search query")}
    else
      user_id = socket.assigns.current_user.id
      lv = self()

      Task.start(fn ->
        result =
          Liteskill.Rag.search_and_rerank(coll_id, query, user_id, top_n: 10, search_limit: 50)

        send(lv, {:rag_search_result, result})
      end)

      {:noreply,
       assign(socket, rag_query_loading: true, rag_query_results: [], rag_query_error: nil)}
    end
  end

  # --- Sources Sidebar Events ---

  @impl true
  def handle_event("toggle_sources_sidebar", %{"message-id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message && message.rag_sources not in [nil, []] do
      if socket.assigns.show_sources_sidebar do
        {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
      else
        {:noreply,
         assign(socket, show_sources_sidebar: true, sidebar_sources: message.rag_sources)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_sources_sidebar", _params, socket) do
    {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
  end

  @impl true
  def handle_event("show_source_modal", %{"chunk-id" => chunk_id}, socket) do
    source = Enum.find(socket.assigns.sidebar_sources, &(&1["chunk_id"] == chunk_id))

    if source do
      {:noreply, assign(socket, show_source_modal: true, source_modal_data: source)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_source_modal", _params, socket) do
    {:noreply, assign(socket, show_source_modal: false)}
  end

  @impl true
  def handle_event("show_source", %{"doc-id" => doc_id}, socket) do
    # Find the source in any assistant message's rag_sources
    {source, _msg_sources} = find_source_by_doc_id(socket.assigns.messages, doc_id)

    source_data =
      source || lookup_source_from_db(doc_id, socket.assigns.current_user.id)

    if source_data do
      {:noreply,
       assign(socket,
         show_source_modal: true,
         source_modal_data: source_data
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Wiki Events ---

  @impl true
  def handle_event("show_wiki_form", params, socket) do
    parent_id = params["parent-id"]

    {:noreply,
     assign(socket,
       show_wiki_form: true,
       wiki_parent_id: parent_id,
       wiki_editing: nil,
       wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page)
     )}
  end

  @impl true
  def handle_event("close_wiki_form", _params, socket) do
    {:noreply, assign(socket, show_wiki_form: false, wiki_editing: nil)}
  end

  @impl true
  def handle_event("create_wiki_page", %{"wiki_page" => params}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id
    parent_id = socket.assigns.wiki_parent_id

    attrs = %{
      title: String.trim(params["title"]),
      content: params["content"] || "",
      content_type: "markdown"
    }

    result =
      if parent_id do
        Liteskill.DataSources.create_child_document(source_ref, parent_id, attrs, user_id)
      else
        Liteskill.DataSources.create_document(source_ref, attrs, user_id)
      end

    case result do
      {:ok, doc} ->
        enqueue_wiki_sync(doc.id, user_id, "upsert")

        {:noreply,
         socket
         |> assign(show_wiki_form: false)
         |> push_navigate(to: ~p"/wiki/#{doc.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create page")}
    end
  end

  @impl true
  def handle_event("edit_wiki_page", _params, socket) do
    doc = socket.assigns.wiki_document

    {:noreply,
     assign(socket,
       wiki_editing: doc,
       wiki_form: to_form(%{"title" => doc.title, "content" => doc.content || ""}, as: :wiki_page)
     )}
  end

  @impl true
  def handle_event("cancel_wiki_edit", _params, socket) do
    {:noreply, assign(socket, wiki_editing: nil)}
  end

  @impl true
  def handle_event("update_wiki_page", %{"wiki_page" => params}, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_editing

    attrs = %{title: String.trim(params["title"]), content: params["content"] || ""}

    case Liteskill.DataSources.update_document(doc.id, attrs, user_id) do
      {:ok, updated} ->
        enqueue_wiki_sync(updated.id, user_id, "upsert")

        {:noreply,
         socket
         |> assign(show_wiki_form: false, wiki_editing: nil, wiki_document: updated)
         |> reload_wiki_page()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update page")}
    end
  end

  @impl true
  def handle_event("delete_wiki_page", _params, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_document

    case Liteskill.DataSources.delete_document(doc.id, user_id) do
      {:ok, _} ->
        enqueue_wiki_sync(doc.id, user_id, "delete")

        redirect_to =
          if doc.parent_document_id,
            do: ~p"/wiki/#{doc.parent_document_id}",
            else: ~p"/wiki"

        {:noreply, push_navigate(socket, to: redirect_to)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete page")}
    end
  end

  @impl true
  def handle_event("open_wiki_export_modal", _params, socket) do
    user_id = socket.assigns.current_user.id
    tree = Liteskill.DataSources.document_tree("builtin:wiki", user_id)

    {:noreply,
     assign(socket,
       show_wiki_export_modal: true,
       wiki_export_title: socket.assigns.report.title,
       wiki_export_parent_id: nil,
       wiki_export_tree: tree
     )}
  end

  @impl true
  def handle_event("close_wiki_export_modal", _params, socket) do
    {:noreply, assign(socket, show_wiki_export_modal: false)}
  end

  @impl true
  def handle_event("confirm_wiki_export", %{"title" => title, "parent_id" => parent_id}, socket) do
    if parent_id == "" do
      {:noreply, put_flash(socket, :error, "Please select a space for the wiki page")}
    else
      user_id = socket.assigns.current_user.id
      report = socket.assigns.report

      case Liteskill.DataSources.export_report_to_wiki(report.id, user_id,
             title: title,
             parent_id: parent_id
           ) do
        {:ok, doc} ->
          enqueue_wiki_sync(doc.id, user_id, "upsert")

          {:noreply,
           socket
           |> assign(show_wiki_export_modal: false)
           |> put_flash(:info, "Report exported to wiki")
           |> push_navigate(to: ~p"/wiki/#{doc.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to export report to wiki")}
      end
    end
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id

      case socket.assigns.conversation do
        nil ->
          # Create new conversation, send message, navigate to it
          case Chat.create_conversation(%{user_id: user_id, title: truncate_title(content)}) do
            {:ok, conversation} ->
              case Chat.send_message(conversation.id, user_id, content) do
                {:ok, _message} ->
                  pid = trigger_llm_stream(conversation, user_id, socket)

                  {:noreply,
                   socket
                   |> assign(stream_task_pid: pid)
                   |> push_navigate(to: ~p"/c/#{conversation.id}")}

                {:error, _reason} ->
                  {:noreply, put_flash(socket, :error, "Failed to send message")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to create conversation")}
          end

        conversation ->
          # Send message to existing conversation
          case Chat.send_message(conversation.id, user_id, content) do
            {:ok, _message} ->
              # Reload messages and trigger LLM
              {:ok, messages} = Chat.list_messages(conversation.id, user_id)
              pid = trigger_llm_stream(conversation, user_id, socket)

              {:noreply,
               socket
               |> assign(
                 messages: messages,
                 form: to_form(%{"content" => ""}, as: :message),
                 streaming: true,
                 stream_content: "",
                 stream_error: nil,
                 pending_tool_calls: [],
                 stream_task_pid: pid
               )}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to send message")}
          end
      end
    end
  end

  @impl true
  def handle_event("confirm_delete_conversation", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  @impl true
  def handle_event("delete_conversation", _params, socket) do
    user_id = socket.assigns.current_user.id
    id = socket.assigns.confirm_delete_id

    case Chat.archive_conversation(id, user_id) do
      {:ok, _} ->
        conversations = Chat.list_conversations(user_id)

        {:noreply,
         socket
         |> assign(conversations: conversations, confirm_delete_id: nil)
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(confirm_delete_id: nil)
         |> put_flash(:error, "Failed to delete conversation")}
    end
  end

  @impl true
  def handle_event("cancel_stream", _params, socket) do
    {:noreply, recover_stuck_stream(socket)}
  end

  @impl true
  def handle_event("retry_message", _params, socket) do
    conversation = socket.assigns.conversation
    user_id = socket.assigns.current_user.id

    if conversation do
      pid = trigger_llm_stream(conversation, user_id, socket)

      {:noreply,
       socket
       |> assign(
         streaming: true,
         stream_content: "",
         stream_error: nil,
         pending_tool_calls: [],
         stream_task_pid: pid
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Tool Picker Events ---

  @impl true
  def handle_event("toggle_tool_picker", _params, socket) do
    show = !socket.assigns.show_tool_picker

    if show && socket.assigns.available_tools == [] do
      # Fetch tools when opening picker for the first time
      send(self(), :fetch_tools)
      {:noreply, assign(socket, show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, show_tool_picker: show)}
    end
  end

  @impl true
  def handle_event("toggle_server", %{"server-id" => server_id}, socket) do
    selected = socket.assigns.selected_server_ids

    selected =
      if MapSet.member?(selected, server_id) do
        MapSet.delete(selected, server_id)
      else
        MapSet.put(selected, server_id)
      end

    {:noreply, assign(socket, selected_server_ids: selected)}
  end

  @impl true
  def handle_event("toggle_auto_confirm", _params, socket) do
    {:noreply, assign(socket, auto_confirm_tools: !socket.assigns.auto_confirm_tools)}
  end

  @impl true
  def handle_event("clear_tools", _params, socket) do
    {:noreply, assign(socket, selected_server_ids: MapSet.new())}
  end

  @impl true
  def handle_event("refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  @impl true
  def handle_event("approve_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    stream_id = socket.assigns.conversation.stream_id

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "tool_approval:#{stream_id}",
      {:tool_decision, tool_use_id, :approved}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("reject_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    stream_id = socket.assigns.conversation.stream_id

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "tool_approval:#{stream_id}",
      {:tool_decision, tool_use_id, :rejected}
    )

    {:noreply, socket}
  end

  # --- MCP Server Events ---

  @impl true
  def handle_event("show_add_mcp", _params, socket) do
    {:noreply,
     assign(socket,
       show_mcp_modal: true,
       editing_mcp: nil,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         )
     )}
  end

  @impl true
  def handle_event("edit_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        headers_json =
          case server.headers do
            nil -> ""
            h when h == %{} -> ""
            h -> Jason.encode!(h, pretty: true)
          end

        {:noreply,
         assign(socket,
           show_mcp_modal: true,
           editing_mcp: server,
           mcp_form:
             to_form(
               %{
                 "name" => server.name,
                 "url" => server.url,
                 "api_key" => server.api_key || "",
                 "description" => server.description || "",
                 "headers" => headers_json,
                 "global" => server.global
               },
               as: :mcp_server
             )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("close_mcp_modal", _params, socket) do
    {:noreply, assign(socket, show_mcp_modal: false, editing_mcp: nil)}
  end

  @impl true
  def handle_event("save_mcp", %{"mcp_server" => params}, socket) do
    user_id = socket.assigns.current_user.id

    headers = parse_headers(params["headers"])
    attrs = Map.merge(params, %{"headers" => headers, "user_id" => user_id})

    result =
      case socket.assigns.editing_mcp do
        nil ->
          McpServers.create_server(attrs)

        server ->
          McpServers.update_server(server, user_id, attrs)
      end

    case result do
      {:ok, _server} ->
        servers = McpServers.list_servers(user_id)

        {:noreply,
         socket
         |> assign(mcp_servers: servers, show_mcp_modal: false, editing_mcp: nil)
         |> put_flash(:info, "Server saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(mcp_form: to_form(changeset, as: :mcp_server))
         |> put_flash(:error, "Please fix the errors")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("delete_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.delete_server(id, user_id) do
      {:ok, _} ->
        servers = McpServers.list_servers(user_id)
        {:noreply, assign(socket, mcp_servers: servers)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete server")}
    end
  end

  @impl true
  def handle_event("delete_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.delete_report(id, user_id) do
      {:ok, _} ->
        reports = Liteskill.Reports.list_reports(user_id)
        {:noreply, assign(socket, reports: reports)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete report")}
    end
  end

  @impl true
  def handle_event("leave_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.leave_report(id, user_id) do
      {:ok, _} ->
        reports = Liteskill.Reports.list_reports(user_id)
        {:noreply, assign(socket, reports: reports)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to leave report")}
    end
  end

  @impl true
  def handle_event("export_report", _params, socket) do
    report = socket.assigns.report
    markdown = socket.assigns.report_markdown

    filename =
      report.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> Kernel.<>(".md")

    {:noreply, push_event(socket, "download_markdown", %{filename: filename, content: markdown})}
  end

  @impl true
  def handle_event("add_section_comment", %{"section_id" => section_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.add_comment(section_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("add_report_comment", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      report_id = socket.assigns.report.id
      Liteskill.Reports.add_report_comment(report_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("reply_to_comment", %{"comment_id" => comment_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.reply_to_comment(comment_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("report_edit_mode", _params, socket) do
    {:noreply, socket |> assign(report_mode: :edit, editing_section_id: nil) |> reload_report()}
  end

  @impl true
  def handle_event("report_view_mode", _params, socket) do
    {:noreply, socket |> assign(report_mode: :view, editing_section_id: nil) |> reload_report()}
  end

  @impl true
  def handle_event("edit_section", %{"section-id" => section_id}, socket) do
    {:noreply, assign(socket, editing_section_id: section_id)}
  end

  @impl true
  def handle_event("cancel_edit_section", _params, socket) do
    {:noreply, assign(socket, editing_section_id: nil)}
  end

  @impl true
  def handle_event("save_section", params, socket) do
    section_id = params["section-id"]
    user_id = socket.assigns.current_user.id

    attrs =
      %{}
      |> then(fn a ->
        if params["content"], do: Map.put(a, :content, params["content"]), else: a
      end)
      |> then(fn a ->
        title = params["title"]

        if is_binary(title) && String.trim(title) != "",
          do: Map.put(a, :title, String.trim(title)),
          else: a
      end)

    case Liteskill.Reports.update_section_content(section_id, user_id, attrs) do
      {:ok, _section} ->
        {:noreply, socket |> assign(editing_section_id: nil) |> reload_report()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update section")}
    end
  end

  @impl true
  def handle_event("address_comments", _params, socket) do
    user_id = socket.assigns.current_user.id
    report = socket.assigns.report

    system_prompt =
      "You are a report editing assistant. You have access to the Reports tools. " <>
        "When asked to address comments, use reports__get to read the report and see all comments. " <>
        "For each [OPEN] comment, make meaningful section updates using reports__modify_sections, " <>
        "then mark the comment as addressed using reports__comment with the \"resolve\" action. " <>
        "If you are unsure how to address a comment, add an agent comment with your question " <>
        "rather than making incorrect changes."

    case Chat.create_conversation(%{
           user_id: user_id,
           title: "Address comments: #{report.title}",
           system_prompt: system_prompt
         }) do
      {:ok, conversation} ->
        content =
          "Please address all unaddressed comments on report #{report.id}. " <>
            "Read the report first, then update sections to address each open comment."

        case Chat.send_message(conversation.id, user_id, content) do
          {:ok, _message} ->
            # Pre-select Reports builtin tools, then trigger the LLM stream
            socket = ensure_tools_loaded(socket)
            socket = select_reports_server(socket)
            pid = trigger_llm_stream(conversation, user_id, socket)

            {:noreply,
             socket
             |> assign(stream_task_pid: pid)
             |> push_navigate(to: ~p"/c/#{conversation.id}")}

          # coveralls-ignore-start
          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
            # coveralls-ignore-stop
        end

      # coveralls-ignore-start
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create conversation")}
        # coveralls-ignore-stop
    end
  end

  @impl true
  def handle_event("toggle_mcp_status", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        new_status = if server.status == "active", do: "inactive", else: "active"

        case McpServers.update_server(server, user_id, %{"status" => new_status}) do
          {:ok, _} ->
            servers = McpServers.list_servers(user_id)
            {:noreply, assign(socket, mcp_servers: servers)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("inspect_tools", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        send(self(), {:fetch_server_tools, server})

        {:noreply,
         assign(socket,
           inspecting_server: server,
           inspecting_tools: [],
           inspecting_tools_loading: true
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("close_tools_modal", _params, socket) do
    {:noreply,
     assign(socket, inspecting_server: nil, inspecting_tools: [], inspecting_tools_loading: false)}
  end

  # --- Profile Event Delegation ---

  @profile_events ~w(change_password promote_user demote_user create_group
    admin_delete_group view_group admin_add_member admin_remove_member set_accent_color)

  def handle_event(event, params, socket) when event in @profile_events do
    ProfileLive.handle_event(event, params, socket)
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:events, _stream_id, events}, socket) do
    socket = Enum.reduce(events, socket, &handle_event_store_event/2)
    {:noreply, socket}
  end

  def handle_info(:reload_after_complete, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    conversations = Chat.list_conversations(user_id)

    # Reload conversation to check actual status — avoids race when
    # StreamHandler immediately starts a new round after completing
    {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)
    still_streaming = fresh_conv.status == "streaming"

    {:noreply,
     assign(socket,
       streaming: still_streaming,
       stream_content: if(still_streaming, do: socket.assigns.stream_content, else: ""),
       messages: messages,
       conversations: conversations,
       conversation: fresh_conv,
       pending_tool_calls: [],
       stream_task_pid: if(still_streaming, do: socket.assigns.stream_task_pid, else: nil)
     )}
  end

  def handle_info(:fetch_tools, socket) do
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)
    active_servers = Enum.filter(servers, &(&1.status == "active"))

    {builtin_servers, mcp_servers} =
      Enum.split_with(active_servers, &Map.has_key?(&1, :builtin))

    builtin_tools =
      Enum.flat_map(builtin_servers, fn server ->
        Enum.map(server.builtin.list_tools(), fn tool ->
          %{
            id: "#{server.id}:#{tool["name"]}",
            server_id: server.id,
            server_name: server.name,
            name: tool["name"],
            description: tool["description"],
            input_schema: tool["inputSchema"]
          }
        end)
      end)

    {mcp_tools, errors} =
      Enum.reduce(mcp_servers, {[], []}, fn server, {tools_acc, errors_acc} ->
        case McpClient.list_tools(server) do
          {:ok, tool_list} ->
            mapped =
              Enum.map(tool_list, fn tool ->
                %{
                  id: "#{server.id}:#{tool["name"]}",
                  server_id: server.id,
                  server_name: server.name,
                  name: tool["name"],
                  description: tool["description"],
                  input_schema: tool["inputSchema"]
                }
              end)

            {tools_acc ++ mapped, errors_acc}

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to fetch tools from #{server.name}: #{inspect(reason)}")
            {tools_acc, errors_acc ++ ["#{server.name}: #{format_tool_error(reason)}"]}
        end
      end)

    socket = assign(socket, available_tools: builtin_tools ++ mcp_tools, tools_loading: false)

    socket =
      if errors != [] do
        put_flash(socket, :error, "Tool fetch failed: " <> Enum.join(errors, "; "))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:fetch_server_tools, %{builtin: module}}, socket) do
    tools = module.list_tools()
    {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}
  end

  def handle_info({:fetch_server_tools, server}, socket) do
    case McpClient.list_tools(server) do
      {:ok, tools} ->
        {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(inspecting_tools_loading: false)
         |> put_flash(:error, "Failed to fetch tools: #{format_tool_error(reason)}")}
    end
  end

  def handle_info({:rag_search_result, {:ok, results}}, socket) do
    chunks = Enum.map(results, & &1.chunk)
    preloaded = Repo.preload(chunks, document: :source)

    enriched =
      Enum.zip_with(results, preloaded, fn result, chunk ->
        %{result | chunk: chunk}
      end)

    {:noreply, assign(socket, rag_query_loading: false, rag_query_results: enriched)}
  end

  def handle_info({:rag_search_result, {:error, reason}}, socket) do
    message =
      case reason do
        %{status: status} -> "Search failed (HTTP #{status})"
        _ -> "Search failed: #{inspect(reason)}"
      end

    {:noreply,
     assign(socket, rag_query_loading: false, rag_query_results: [], rag_query_error: message)}
  end

  def handle_info(:reload_tool_calls, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    db_pending = load_pending_tool_calls(messages)

    # During streaming, load_pending_tool_calls returns [] because the message
    # hasn't completed with stop_reason: "tool_use" yet. Keep the in-memory
    # pending_tool_calls built from PubSub events in that case.
    pending =
      if db_pending != [] do
        db_pending
      else
        if socket.assigns.streaming && socket.assigns.pending_tool_calls != [] do
          socket.assigns.pending_tool_calls
        else
          []
        end
      end

    {:noreply, assign(socket, messages: messages, pending_tool_calls: pending)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket)
      when reason != :normal do
    if socket.assigns.streaming && pid == socket.assigns.stream_task_pid do
      {:noreply, recover_stuck_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_event_store_event(
         %{event_type: "AssistantStreamStarted"},
         socket
       ) do
    assign(socket, streaming: true, stream_content: "", stream_error: nil)
  end

  defp handle_event_store_event(
         %{event_type: "AssistantChunkReceived", data: data},
         socket
       ) do
    delta = data["delta_text"] || ""
    assign(socket, stream_content: socket.assigns.stream_content <> delta)
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamCompleted"},
         socket
       ) do
    # Delay reload to let the Projector finish updating the DB.
    # Keep streaming content visible until then.
    Process.send_after(self(), :reload_after_complete, 100)
    socket
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamFailed", data: data},
         socket
       ) do
    error = friendly_stream_error(data["error_type"], data["error_message"])

    socket
    |> assign(streaming: false, stream_content: "", stream_error: error)
  end

  defp handle_event_store_event(
         %{event_type: "UserMessageAdded"},
         socket
       ) do
    # Reload messages (handles shared conversations)
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    assign(socket, messages: messages)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallStarted", data: data},
         socket
       ) do
    # Build tool call immediately from event data to avoid race with projector
    tc = %ToolCall{
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: "started",
      message_id: data["message_id"]
    }

    pending = socket.assigns.pending_tool_calls ++ [tc]

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallCompleted", data: data},
         socket
       ) do
    # Update the pending tool call status immediately
    tool_use_id = data["tool_use_id"]

    pending =
      Enum.map(socket.assigns.pending_tool_calls, fn tc ->
        if tc.tool_use_id == tool_use_id do
          %{tc | status: "completed", output: data["output"]}
        else
          tc
        end
      end)

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(_event, socket), do: socket

  # --- Helpers ---

  defp trigger_llm_stream(conversation, user_id, socket) do
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)

    llm_messages = build_llm_messages(messages)

    # RAG context augmentation
    last_user_msg = messages |> Enum.filter(&(&1.role == "user")) |> List.last()
    query = if last_user_msg, do: last_user_msg.content

    {rag_results, rag_sources_json} =
      if query && String.trim(query) != "" do
        case Liteskill.Rag.augment_context(query, user_id) do
          {:ok, results} when results != [] ->
            {results, Liteskill.LLM.RagContext.serialize_sources(results)}

          _ ->
            {[], nil}
        end
      else
        {[], nil}
      end

    system_prompt =
      Liteskill.LLM.RagContext.build_system_prompt(rag_results, conversation.system_prompt)

    opts = if system_prompt, do: [system: system_prompt], else: []

    # Add tool options if tools are selected
    opts = opts ++ build_tool_opts(socket)

    # Pass rag_sources through the event store so they survive navigation
    opts = if rag_sources_json, do: [{:rag_sources, rag_sources_json} | opts], else: opts

    {:ok, pid} =
      Task.start(fn ->
        StreamHandler.handle_stream(conversation.stream_id, llm_messages, opts)
      end)

    Process.monitor(pid)
    pid
  end

  defp build_tool_opts(socket) do
    selected = socket.assigns.selected_server_ids
    available = socket.assigns.available_tools

    # Select all tools from selected servers
    selected_tools = Enum.filter(available, &MapSet.member?(selected, &1.server_id))

    if selected_tools == [] do
      []
    else
      bedrock_tools =
        Enum.map(selected_tools, fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool.name,
              "description" => tool.description || "",
              "inputSchema" => %{"json" => tool.input_schema || %{}}
            }
          }
        end)

      user_id = socket.assigns.current_user.id

      tool_servers =
        Map.new(selected_tools, fn tool ->
          server =
            case McpServers.get_server(tool.server_id, user_id) do
              {:ok, s} -> s
              _ -> nil
            end

          {tool.name, server}
        end)

      [
        tools: bedrock_tools,
        tool_servers: tool_servers,
        auto_confirm: socket.assigns.auto_confirm_tools,
        user_id: user_id
      ]
    end
  end

  defp reload_wiki_page(socket) do
    user_id = socket.assigns.current_user.id
    doc_id = socket.assigns.wiki_document.id

    case Liteskill.DataSources.get_document(doc_id, user_id) do
      {:ok, doc} ->
        space = socket.assigns.wiki_space

        tree =
          if space do
            Liteskill.DataSources.space_tree("builtin:wiki", space.id, user_id)
          else
            []
          end

        assign(socket, wiki_document: doc, wiki_tree: tree, wiki_sidebar_tree: tree)

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end

  defp reload_report(socket) do
    report = socket.assigns.report
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report.id, user_id) do
      {:ok, report} ->
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report.id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        include_comments = socket.assigns[:report_mode] != :view
        markdown = Liteskill.Reports.render_markdown(report, include_comments: include_comments)

        assign(socket,
          report: report,
          section_tree: section_tree,
          report_comments: report_comments,
          report_markdown: markdown
        )

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end

  defp ensure_tools_loaded(socket) do
    if socket.assigns.available_tools == [] do
      user_id = socket.assigns.current_user.id
      servers = Liteskill.McpServers.list_servers(user_id)
      active_servers = Enum.filter(servers, &(&1.status == "active"))

      builtin_tools =
        active_servers
        |> Enum.filter(&Map.has_key?(&1, :builtin))
        |> Enum.flat_map(fn server ->
          Enum.map(server.builtin.list_tools(), fn tool ->
            %{
              id: "#{server.id}:#{tool["name"]}",
              server_id: server.id,
              server_name: server.name,
              name: tool["name"],
              description: tool["description"],
              input_schema: tool["inputSchema"]
            }
          end)
        end)

      assign(socket, available_tools: builtin_tools)
    else
      socket
    end
  end

  defp select_reports_server(socket) do
    reports_server =
      Enum.find(socket.assigns.available_tools, fn tool ->
        String.starts_with?(tool.name, "reports__")
      end)

    case reports_server do
      nil ->
        socket

      tool ->
        assign(socket, selected_server_ids: MapSet.new([tool.server_id]))
    end
  end

  defp build_llm_messages(messages) do
    messages
    |> Repo.preload(:tool_calls)
    |> Enum.filter(&(&1.status == "complete"))
    |> Enum.reduce([], fn msg, acc ->
      case msg.role do
        "user" ->
          if msg.content && msg.content != "" do
            acc ++ [%{"role" => "user", "content" => [%{"text" => msg.content}]}]
          else
            acc
          end

        "assistant" ->
          if msg.stop_reason == "tool_use" do
            # Build assistant message with text + toolUse blocks
            text_blocks =
              if msg.content && msg.content != "" do
                [%{"text" => msg.content}]
              else
                []
              end

            completed_tcs = Enum.filter(msg.tool_calls, &(&1.status == "completed"))

            tool_use_blocks =
              Enum.map(msg.tool_calls, fn tc ->
                %{
                  "toolUse" => %{
                    "toolUseId" => tc.tool_use_id,
                    "name" => tc.tool_name,
                    "input" => tc.input || %{}
                  }
                }
              end)

            content = text_blocks ++ tool_use_blocks
            assistant_msg = %{"role" => "assistant", "content" => content}

            # Build tool result user message from completed tool calls
            if completed_tcs != [] do
              tool_results =
                Enum.map(completed_tcs, fn tc ->
                  %{
                    "toolResult" => %{
                      "toolUseId" => tc.tool_use_id,
                      "content" => [%{"text" => format_tool_output_for_msg(tc.output)}],
                      "status" => "success"
                    }
                  }
                end)

              acc ++ [assistant_msg, %{"role" => "user", "content" => tool_results}]
            else
              acc ++ [assistant_msg]
            end
          else
            if msg.content && msg.content != "" do
              acc ++ [%{"role" => "assistant", "content" => [%{"text" => msg.content}]}]
            else
              acc
            end
          end
      end
    end)
    |> merge_consecutive_roles()
  end

  # Merge consecutive same-role messages (can happen when failed assistant
  # messages are filtered out, leaving adjacent user messages).
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case acc do
          nil ->
            {:cont, msg}

          %{"role" => role} ->
            if role == msg["role"] do
              merged = %{acc | "content" => acc["content"] ++ msg["content"]}
              {:cont, merged}
            else
              {:cont, acc, msg}
            end
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp format_tool_output_for_msg(nil), do: ""

  defp format_tool_output_for_msg(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp format_tool_output_for_msg(output) when is_map(output), do: Jason.encode!(output)
  defp format_tool_output_for_msg(output), do: inspect(output)

  defp tool_calls_for_message(msg) do
    case msg.tool_calls do
      %Ecto.Association.NotLoaded{} ->
        Repo.all(
          from tc in ToolCall, where: tc.message_id == ^msg.id, order_by: [asc: tc.inserted_at]
        )

      tool_calls ->
        tool_calls
    end
  end

  defp load_pending_tool_calls(messages) do
    case List.last(messages) do
      %{role: "assistant", stop_reason: "tool_use"} = msg ->
        tool_calls_for_message(msg)
        |> Enum.filter(&(&1.status == "started"))

      _ ->
        []
    end
  end

  defp get_wiki_source, do: Liteskill.BuiltinSources.find("builtin:wiki")

  defp source_id_from_url("builtin-" <> rest), do: "builtin:" <> rest
  defp source_id_from_url(id), do: id

  defp maybe_unsubscribe(socket) do
    case socket.assigns[:conversation] do
      %{stream_id: stream_id} when not is_nil(stream_id) ->
        Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "event_store:#{stream_id}")

      _ ->
        :ok
    end
  end

  defp truncate_title(content) do
    case String.split(content, "\n", parts: 2) do
      [first | _] ->
        if String.length(first) > 50 do
          String.slice(first, 0, 47) <> "..."
        else
          first
        end
    end
  end

  defp parse_headers(str) when is_binary(str) do
    str = String.trim(str)

    if str == "" do
      %{}
    else
      case Jason.decode(str) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end
  end

  defp parse_headers(_), do: %{}

  defp recover_stuck_stream(socket) do
    conversation = socket.assigns.conversation

    if conversation do
      user_id = socket.assigns.current_user.id

      # Find the streaming message to get its ID for fail_stream
      streaming_msg =
        Repo.one(
          from m in Liteskill.Chat.Message,
            where: m.conversation_id == ^conversation.id and m.status == "streaming",
            order_by: [desc: m.inserted_at],
            limit: 1
        )

      if streaming_msg do
        alias Liteskill.Aggregate.Loader
        alias Liteskill.Chat.{ConversationAggregate, Projector}

        command =
          {:fail_stream,
           %{
             message_id: streaming_msg.id,
             error_type: "task_crashed",
             error_message: "Stream handler process terminated unexpectedly"
           }}

        case Loader.execute(ConversationAggregate, conversation.stream_id, command) do
          {:ok, _state, events} ->
            Projector.project_events(conversation.stream_id, events)
            Process.sleep(100)

          {:error, _reason} ->
            :ok
        end
      end

      {:ok, messages} = Chat.list_messages(conversation.id, user_id)
      {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

      socket
      |> assign(
        streaming: false,
        stream_content: "",
        messages: messages,
        conversation: fresh_conv,
        pending_tool_calls: [],
        stream_task_pid: nil
      )
    else
      assign(socket, streaming: false, stream_content: "", stream_task_pid: nil)
    end
  end

  defp find_source_by_doc_id(messages, doc_id) do
    msg =
      Enum.find(messages, fn m ->
        m.role == "assistant" && m.rag_sources &&
          Enum.any?(m.rag_sources, &(&1["document_id"] == doc_id))
      end)

    if msg do
      source = Enum.find(msg.rag_sources, &(&1["document_id"] == doc_id))
      {source, msg.rag_sources}
    else
      {nil, []}
    end
  end

  defp lookup_source_from_db(doc_id, user_id) do
    alias Liteskill.Rag

    with {:ok, doc} <- Rag.get_document(doc_id, user_id) do
      doc = Liteskill.Repo.preload(doc, :source)
      wiki_doc_id = get_in(doc.metadata || %{}, ["wiki_document_id"])

      %{
        "chunk_id" => nil,
        "document_id" => doc.id,
        "document_title" => doc.title,
        "source_name" => doc.source.name,
        "content" => doc.content,
        "position" => nil,
        "relevance_score" => nil,
        "source_uri" => if(wiki_doc_id, do: "/wiki/#{wiki_doc_id}")
      }
    else
      _ -> nil
    end
  end

  defp enqueue_wiki_sync(wiki_document_id, user_id, action) do
    Liteskill.Rag.WikiSyncWorker.new(%{
      "wiki_document_id" => wiki_document_id,
      "user_id" => user_id,
      "action" => action
    })
    |> Oban.insert()
  end

  defp format_tool_error(%{status: status, body: body}) when is_binary(body),
    do: "HTTP #{status}: #{String.slice(body, 0..100)}"

  defp format_tool_error(%{status: status}), do: "HTTP #{status}"
  defp format_tool_error(%Req.TransportError{reason: reason}), do: "Connection error: #{reason}"
  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)

  defp friendly_stream_error("max_retries_exceeded", _msg) do
    %{
      title: "The AI service is currently busy",
      detail: "Too many requests — please wait a moment and retry."
    }
  end

  defp friendly_stream_error("request_error", msg) when is_binary(msg) do
    cond do
      msg =~ "timeout" or msg =~ "Timeout" ->
        %{
          title: "Request timed out",
          detail: "The AI service took too long to respond. Please try again."
        }

      msg =~ "closed" or msg =~ "connection" ->
        %{
          title: "Connection lost",
          detail: "Lost connection to the AI service. Please try again."
        }

      true ->
        %{
          title: "Something went wrong",
          detail: "An unexpected error occurred. Please try again."
        }
    end
  end

  defp friendly_stream_error(_type, _msg) do
    %{
      title: "Something went wrong",
      detail: "An unexpected error occurred. Please try again."
    }
  end
end
