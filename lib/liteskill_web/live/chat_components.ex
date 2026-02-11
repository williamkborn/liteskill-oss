defmodule LiteskillWeb.ChatComponents do
  @moduledoc """
  Reusable function components for the chat UI.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: LiteskillWeb.Endpoint,
    router: LiteskillWeb.Router,
    statics: LiteskillWeb.static_paths()

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :message, :map, required: true

  def message_bubble(assigns) do
    ~H"""
    <%= if @message.role == "user" do %>
      <div class="flex w-full mb-4 justify-end">
        <div class="max-w-[75%] rounded-2xl rounded-br-sm px-4 py-3 bg-primary text-primary-content">
          <p class="whitespace-pre-wrap break-words text-sm">{@message.content}</p>
        </div>
      </div>
    <% else %>
      <div class="mb-4 text-base-content">
        <div id={"prose-#{@message.id}"} phx-hook="CopyCode" class="prose prose-sm max-w-none">
          {LiteskillWeb.Markdown.render(@message.content)}
        </div>
      </div>
    <% end %>
    """
  end

  attr :conversation, :map, required: true
  attr :active, :boolean, default: false

  def conversation_item(assigns) do
    ~H"""
    <div class={[
      "group flex items-center gap-1 rounded-lg transition-colors",
      if(@active,
        do: "bg-primary/10 text-primary font-medium",
        else: "hover:bg-base-200 text-base-content"
      )
    ]}>
      <button
        phx-click="select_conversation"
        phx-value-id={@conversation.id}
        class="flex-1 text-left px-3 py-2 text-sm truncate cursor-pointer"
      >
        {@conversation.title}
      </button>
      <button
        phx-click="confirm_delete_conversation"
        phx-value-id={@conversation.id}
        class="opacity-0 group-hover:opacity-100 pr-2 text-base-content/40 hover:text-error transition-opacity cursor-pointer"
      >
        <.icon name="hero-trash-micro" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :error, :map, required: true

  def stream_error(assigns) do
    ~H"""
    <div class="flex justify-start mb-4">
      <div class="bg-error/10 border border-error/20 rounded-2xl rounded-bl-sm px-4 py-3 max-w-lg">
        <div class="flex items-start gap-2">
          <.icon name="hero-exclamation-triangle-mini" class="size-5 text-error shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-error">{@error.title}</p>
            <p class="text-xs text-base-content/60 mt-1">{@error.detail}</p>
            <button
              phx-click="retry_message"
              class="btn btn-error btn-outline btn-xs mt-2"
            >
              <.icon name="hero-arrow-path-micro" class="size-3" /> Retry
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def streaming_indicator(assigns) do
    ~H"""
    <div class="flex justify-start mb-4">
      <div class="bg-base-200 rounded-2xl rounded-bl-sm px-4 py-3">
        <div class="flex gap-1 items-center">
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:-0.3s]" />
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:-0.15s]" />
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce" />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :show, :boolean, required: true
  attr :on_close, :string, required: true
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={@show && Phoenix.LiveView.JS.focus_first(to: "##{@id}-content")}
    >
      <div class="fixed inset-0 bg-black/50" phx-click={@on_close} />
      <div
        id={"#{@id}-content"}
        class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-lg mx-4 max-h-[90vh] overflow-y-auto"
      >
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">{@title}</h3>
          <button phx-click={@on_close} class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="p-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :confirm_event, :string, required: true
  attr :cancel_event, :string, required: true

  def confirm_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown={@cancel_event}
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click={@cancel_event} />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-sm mx-4 z-10">
        <div class="p-5">
          <h3 class="text-lg font-semibold mb-2">{@title}</h3>
          <p class="text-sm text-base-content/70">{@message}</p>
        </div>
        <div class="flex justify-end gap-2 px-5 pb-5">
          <button phx-click={@cancel_event} class="btn btn-ghost btn-sm">Cancel</button>
          <button phx-click={@confirm_event} class="btn btn-error btn-sm">Archive</button>
        </div>
      </div>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :owned, :boolean, required: true

  def mcp_server_card(assigns) do
    assigns = assign(assigns, :builtin?, Map.has_key?(assigns.server, :builtin))

    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold text-sm truncate">{@server.name}</h3>
            <p :if={@server.url} class="text-xs text-base-content/60 truncate mt-0.5">
              {@server.url}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <span :if={@builtin?} class="badge badge-sm badge-primary">built-in</span>
            <span class={[
              "badge badge-sm",
              if(@server.status == "active", do: "badge-success", else: "badge-ghost")
            ]}>
              {@server.status}
            </span>
          </div>
        </div>
        <p :if={@server.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
          {@server.description}
        </p>
        <div :if={!@builtin? && @server.global} class="flex items-center gap-1 mt-2">
          <span class="badge badge-xs badge-info">global</span>
        </div>
        <div class="card-actions justify-end mt-2">
          <button
            phx-click="inspect_tools"
            phx-value-id={@server.id}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-code-bracket-micro" class="size-4" /> Tools
          </button>
          <button
            :if={@owned && !@builtin?}
            phx-click="edit_mcp"
            phx-value-id={@server.id}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
          </button>
          <button
            :if={@owned && !@builtin?}
            phx-click="delete_mcp"
            phx-value-id={@server.id}
            data-confirm="Delete this MCP server?"
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-4" /> Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Source Card ---

  attr :source, :map, required: true

  def source_card(assigns) do
    assigns = assign(assigns, :builtin?, Map.get(assigns.source, :builtin, false))

    ~H"""
    <.link navigate={~p"/sources/#{source_url_id(@source)}"} class="block">
      <div class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer">
        <div class="card-body p-4">
          <div class="flex items-start justify-between gap-2">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <.icon name={source_icon(@source)} class="size-4 text-base-content/60" />
                <h3 class="font-semibold text-sm truncate">{@source.name}</h3>
              </div>
              <p :if={@source.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
                {@source.description}
              </p>
            </div>
            <div class="flex items-center gap-1">
              <span :if={@builtin?} class="badge badge-sm badge-primary">built-in</span>
            </div>
          </div>
          <div class="flex items-center justify-between mt-2">
            <span class="text-xs text-base-content/50">
              {Map.get(@source, :document_count, 0)} {if Map.get(@source, :document_count, 0) == 1,
                do: "document",
                else: "documents"}
            </span>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp source_icon(%{icon: icon}), do: icon
  defp source_icon(_), do: "hero-folder-micro"

  def source_url_id(%{id: "builtin:" <> rest}), do: "builtin-" <> rest
  def source_url_id(%{id: id}), do: id

  # --- Document List ---

  attr :space, :map, required: true

  def space_card(assigns) do
    ~H"""
    <.link navigate={~p"/wiki/#{@space.id}"} class="block">
      <div class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer">
        <div class="card-body p-4">
          <div class="flex items-center gap-2">
            <.icon
              name="hero-rectangle-group-micro"
              class="size-4 text-base-content/60 flex-shrink-0"
            />
            <h3 class="font-semibold text-sm truncate">{@space.title}</h3>
          </div>
          <p
            :if={@space.content && @space.content != ""}
            class="text-xs text-base-content/70 mt-1 line-clamp-2"
          >
            {String.slice(@space.content, 0..200)}
          </p>
          <div class="flex items-center mt-2">
            <span class="text-xs text-base-content/50">
              {Calendar.strftime(@space.updated_at, "%b %d, %Y")}
            </span>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  attr :source, :map, required: true
  attr :result, :map, required: true
  attr :search, :string, required: true

  def document_list(assigns) do
    ~H"""
    <div class="space-y-4">
      <form phx-change="source_search" phx-submit="source_search" class="form-control">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass-micro"
            class="size-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="text"
            name="search"
            value={@search}
            placeholder="Search documents..."
            phx-debounce="300"
            class="input input-bordered input-sm w-full pl-9"
          />
        </div>
      </form>

      <div :if={@result.documents != []} class="space-y-2">
        <.link
          :for={doc <- @result.documents}
          navigate={document_url(@source, doc)}
          class="block card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer p-3"
        >
          <div class="flex items-start justify-between gap-2">
            <div class="flex-1 min-w-0">
              <h4 class="font-medium text-sm truncate">{doc.title}</h4>
              <p :if={doc.content} class="text-xs text-base-content/60 mt-1 line-clamp-2">
                {String.slice(doc.content || "", 0..200)}
              </p>
            </div>
            <span class="badge badge-ghost badge-xs flex-shrink-0">{doc.content_type}</span>
          </div>
          <div class="flex items-center gap-3 mt-2 text-xs text-base-content/40">
            <span>{Calendar.strftime(doc.updated_at, "%b %d, %Y")}</span>
            <span :if={doc.slug} class="truncate">/{doc.slug}</span>
          </div>
        </.link>
      </div>

      <p
        :if={@result.documents == [] && @search != ""}
        class="text-base-content/50 text-center py-8 text-sm"
      >
        No documents matching "{@search}"
      </p>

      <p
        :if={@result.documents == [] && @search == ""}
        class="text-base-content/50 text-center py-8 text-sm"
      >
        No documents yet.
      </p>

      <div :if={@result.total_pages > 1} class="flex justify-center gap-1 pt-2">
        <button
          :if={@result.page > 1}
          phx-click="source_page"
          phx-value-page={@result.page - 1}
          class="btn btn-ghost btn-xs"
        >
          Previous
        </button>
        <span class="btn btn-ghost btn-xs no-animation">
          {@result.page} / {@result.total_pages}
        </span>
        <button
          :if={@result.page < @result.total_pages}
          phx-click="source_page"
          phx-value-page={@result.page + 1}
          class="btn btn-ghost btn-xs"
        >
          Next
        </button>
      </div>
    </div>
    """
  end

  # --- Wiki Children ---

  attr :source, :map, required: true
  attr :document, :map, required: true
  attr :tree, :list, required: true

  def wiki_children(assigns) do
    children = find_children_in_tree(assigns.tree, assigns.document.id)
    assigns = assign(assigns, :children, children)

    ~H"""
    <div :if={@children != []} class="border-t border-base-300 pt-4">
      <h3 class="text-sm font-semibold text-base-content/70 mb-3">Child Pages</h3>
      <div class="space-y-2">
        <.link
          :for={child <- @children}
          navigate={~p"/wiki/#{child.document.id}"}
          class="block card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer p-3"
        >
          <h4 class="font-medium text-sm">{child.document.title}</h4>
          <p
            :if={child.document.content && child.document.content != ""}
            class="text-xs text-base-content/60 mt-1 line-clamp-2"
          >
            {String.slice(child.document.content, 0..200)}
          </p>
        </.link>
      </div>
    </div>
    """
  end

  defp document_url(%{id: "builtin:wiki"}, doc), do: ~p"/wiki/#{doc.id}"
  defp document_url(source, _doc), do: ~p"/sources/#{source_url_id(source)}"

  # --- Wiki Tree Sidebar ---

  attr :tree, :list, required: true
  attr :active_doc_id, :string, default: nil

  def wiki_tree_sidebar(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={node <- @tree}>
        <.link
          navigate={~p"/wiki/#{node.document.id}"}
          class={[
            "flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors truncate",
            if(@active_doc_id == node.document.id,
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-document-text-micro" class="size-3 flex-shrink-0" />
          <span class="truncate">{node.document.title}</span>
        </.link>
        <div :if={node.children != []} class="ml-3">
          <.wiki_tree_sidebar tree={node.children} active_doc_id={@active_doc_id} />
        </div>
      </li>
    </ul>
    """
  end

  defp find_children_in_tree([], _id), do: []

  defp find_children_in_tree(tree, id) do
    case Enum.find(tree, fn node -> node.document.id == id end) do
      nil -> Enum.flat_map(tree, fn node -> find_children_in_tree(node.children, id) end)
      node -> node.children
    end
  end

  attr :node, :map, required: true
  attr :depth, :integer, required: true
  attr :selected, :string, default: nil

  def wiki_parent_option(assigns) do
    ~H"""
    <option value={@node.document.id} selected={@selected == @node.document.id}>
      {String.duplicate("\u00A0\u00A0", @depth)}
      <%= if @depth > 0 do %>
        └
      <% end %>
      {@node.document.title}
    </option>
    <%= for child <- @node.children do %>
      <.wiki_parent_option node={child} depth={@depth + 1} selected={@selected} />
    <% end %>
    """
  end

  # --- Server Picker ---

  attr :available_tools, :list, required: true
  attr :selected_server_ids, :any, required: true
  attr :show, :boolean, required: true
  attr :auto_confirm, :boolean, required: true
  attr :tools_loading, :boolean, default: false

  def server_picker(assigns) do
    servers =
      assigns.available_tools
      |> Enum.group_by(& &1.server_id)
      |> Enum.map(fn {server_id, tools} ->
        first = hd(tools)
        %{id: server_id, name: first.server_name, tool_count: length(tools)}
      end)

    assigns =
      assign(assigns,
        selected_count: MapSet.size(assigns.selected_server_ids),
        servers: servers
      )

    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_tool_picker"
        class={[
          "btn btn-ghost btn-sm gap-1",
          if(@selected_count > 0, do: "text-primary", else: "text-base-content/50")
        ]}
      >
        <.icon name="hero-server-stack-micro" class="size-4" />
        <span :if={@selected_count > 0} class="badge badge-primary badge-xs">
          {@selected_count}
        </span>
      </button>

      <div
        :if={@show}
        class="absolute bottom-full left-0 mb-2 w-72 bg-base-100 border border-base-300 rounded-xl shadow-lg z-50 max-h-96 overflow-y-auto"
        phx-click-away="toggle_tool_picker"
      >
        <div class="p-3 border-b border-base-300 flex items-center justify-between">
          <span class="text-sm font-semibold">MCP Servers</span>
          <button
            :if={@selected_count > 0}
            type="button"
            phx-click="clear_tools"
            class="btn btn-ghost btn-xs text-base-content/50"
          >
            Clear
          </button>
        </div>

        <div :if={@tools_loading} class="p-4 text-center text-sm text-base-content/50">
          Loading servers...
        </div>

        <div
          :if={!@tools_loading && @servers == []}
          class="p-4 text-center text-sm text-base-content/50"
        >
          <p>No MCP servers found</p>
          <button
            type="button"
            phx-click="refresh_tools"
            class="btn btn-ghost btn-xs mt-2 gap-1"
          >
            <.icon name="hero-arrow-path-micro" class="size-3" /> Retry
          </button>
        </div>

        <div :if={!@tools_loading && @servers != []} class="py-1">
          <div
            :for={server <- @servers}
            class="flex items-center gap-2 px-3 py-2 hover:bg-base-200"
          >
            <label class="flex items-center gap-2 flex-1 min-w-0 cursor-pointer">
              <input
                type="checkbox"
                phx-click="toggle_server"
                phx-value-server-id={server.id}
                checked={MapSet.member?(@selected_server_ids, server.id)}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate">{server.name}</div>
                <div class="text-xs text-base-content/60">
                  {server.tool_count} {if server.tool_count == 1, do: "tool", else: "tools"}
                </div>
              </div>
            </label>
            <button
              type="button"
              phx-click="inspect_tools"
              phx-value-id={server.id}
              class="text-base-content/40 hover:text-info"
            >
              <.icon name="hero-information-circle-micro" class="size-4" />
            </button>
          </div>
        </div>

        <div class="p-3 border-t border-base-300">
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              phx-click="toggle_auto_confirm"
              checked={@auto_confirm}
              class="toggle toggle-xs toggle-primary"
            />
            <span class="text-xs text-base-content/70">Auto-confirm tool calls</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  # --- Tool Call Display ---

  attr :tool_call, :map, required: true
  attr :show_actions, :boolean, default: false

  def tool_call_display(assigns) do
    ~H"""
    <div class="flex justify-start mb-3">
      <div class="max-w-[85%] bg-base-200/50 border border-base-300 rounded-lg px-3 py-2 text-xs">
        <div class="flex items-center gap-2">
          <.icon name="hero-wrench-screwdriver-micro" class="size-3.5 text-base-content/50" />
          <span class="font-medium">{@tool_call.tool_name}</span>
          <span class={[
            "badge badge-xs",
            case @tool_call.status do
              "started" -> "badge-warning"
              "completed" -> "badge-success"
              _ -> "badge-ghost"
            end
          ]}>
            {@tool_call.status}
          </span>
        </div>

        <details :if={@tool_call.input && @tool_call.input != %{}} class="mt-1">
          <summary class="cursor-pointer text-base-content/50 hover:text-base-content/70">
            Input
          </summary>
          <pre class="mt-1 p-2 bg-base-300/50 rounded text-[0.65rem] overflow-x-auto whitespace-pre-wrap">{Jason.encode!(@tool_call.input, pretty: true)}</pre>
        </details>

        <details :if={@tool_call.output} class="mt-1">
          <summary class="cursor-pointer text-base-content/50 hover:text-base-content/70">
            Output
          </summary>
          <pre class="mt-1 p-2 bg-base-300/50 rounded text-[0.65rem] overflow-x-auto whitespace-pre-wrap">{Jason.encode!(@tool_call.output, pretty: true)}</pre>
        </details>

        <div :if={@show_actions && @tool_call.status == "started"} class="flex gap-2 mt-2">
          <button
            phx-click="approve_tool_call"
            phx-value-tool-use-id={@tool_call.tool_use_id}
            class="btn btn-success btn-xs gap-1"
          >
            <.icon name="hero-check-micro" class="size-3" /> Approve
          </button>
          <button
            phx-click="reject_tool_call"
            phx-value-tool-use-id={@tool_call.tool_use_id}
            class="btn btn-error btn-xs gap-1"
          >
            <.icon name="hero-x-mark-micro" class="size-3" /> Reject
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Selected Server Badges ---

  attr :available_tools, :list, required: true
  attr :selected_server_ids, :any, required: true

  def selected_server_badges(assigns) do
    selected_servers =
      assigns.available_tools
      |> Enum.group_by(& &1.server_id)
      |> Enum.filter(fn {server_id, _} ->
        MapSet.member?(assigns.selected_server_ids, server_id)
      end)
      |> Enum.map(fn {server_id, tools} -> %{id: server_id, name: hd(tools).server_name} end)

    assigns = assign(assigns, selected_servers: selected_servers)

    ~H"""
    <div :if={@selected_servers != []} class="flex flex-wrap gap-1 px-1 pb-1">
      <span
        :for={server <- @selected_servers}
        class="badge badge-sm badge-outline badge-primary gap-1"
      >
        {server.name}
        <button
          type="button"
          phx-click="toggle_server"
          phx-value-server-id={server.id}
          class="hover:text-error"
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </button>
      </span>
    </div>
    """
  end

  # --- Tool Detail ---

  attr :tool, :map, required: true

  def tool_detail(assigns) do
    properties = get_in(assigns.tool, ["inputSchema", "properties"]) || %{}
    required_fields = get_in(assigns.tool, ["inputSchema", "required"]) || []

    params =
      Enum.map(properties, fn {name, schema} ->
        %{
          name: name,
          type: schema["type"] || "any",
          description: schema["description"],
          required: name in required_fields
        }
      end)
      |> Enum.sort_by(&(!&1.required))

    assigns = assign(assigns, params: params)

    ~H"""
    <div class="collapse collapse-arrow border border-base-300 bg-base-200/30 rounded-lg">
      <input type="checkbox" />
      <div class="collapse-title py-2 px-3 min-h-0">
        <span class="font-mono text-sm font-semibold">{@tool["name"]}</span>
      </div>
      <div class="collapse-content px-3 pb-3 text-xs">
        <p :if={@tool["description"]} class="text-base-content/70 mb-3">
          {@tool["description"]}
        </p>
        <div :if={@params != []} class="space-y-2">
          <h4 class="font-semibold text-base-content/80">Parameters</h4>
          <div :for={param <- @params} class="flex flex-col gap-0.5 pl-2 border-l-2 border-base-300">
            <div class="flex items-center gap-2">
              <code class="text-primary font-semibold">{param.name}</code>
              <span class="badge badge-xs badge-ghost">{param.type}</span>
              <span :if={param.required} class="badge badge-xs badge-warning">required</span>
            </div>
            <p :if={param.description} class="text-base-content/60">{param.description}</p>
          </div>
        </div>
        <p :if={@params == []} class="text-base-content/50 italic">No parameters</p>
      </div>
    </div>
    """
  end

  # --- Report Section Components ---

  attr :node, :map, required: true
  attr :depth, :integer, required: true
  attr :editing_section_id, :string, default: nil

  def section_node(assigns) do
    tag = heading_tag(assigns.depth)
    editing? = assigns.editing_section_id == assigns.node.section.id
    assigns = assigns |> assign(:tag, tag) |> assign(:editing?, editing?)

    ~H"""
    <div class="mb-4 group/section" id={"section-#{@node.section.id}"}>
      <%= if @editing? do %>
        <div
          id={"editor-#{@node.section.id}"}
          phx-hook="SectionEditor"
          phx-update="ignore"
          data-content={@node.section.content || ""}
          data-section-id={@node.section.id}
          data-title={@node.section.title}
          class="mt-2 border border-base-300 rounded-lg overflow-hidden"
        >
          <div class="px-3 pt-2">
            <input
              type="text"
              data-title-input
              value={@node.section.title}
              class={"input input-bordered input-sm w-full font-semibold #{heading_class(@depth)}"}
              placeholder="Section title"
            />
          </div>
          <div data-editor-target class="min-h-[100px]"></div>
          <div class="flex justify-end gap-2 p-2 border-t border-base-300 bg-base-200/50">
            <button
              type="button"
              phx-click="cancel_edit_section"
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </button>
            <button type="button" data-action="save" class="btn btn-primary btn-sm">
              Save
            </button>
          </div>
        </div>
      <% else %>
        <div class="flex items-center gap-2">
          <span class={"font-semibold #{heading_class(@depth)}"}>{@node.section.title}</span>
          <button
            :if={is_nil(@editing_section_id)}
            phx-click="edit_section"
            phx-value-section-id={@node.section.id}
            class="btn btn-ghost btn-xs opacity-0 group-hover/section:opacity-100 transition-opacity"
            title="Edit section"
          >
            <.icon name="hero-pencil-square-micro" class="size-3.5" />
          </button>
        </div>

        <div
          :if={@node.section.content && @node.section.content != ""}
          class="prose prose-sm max-w-none mt-1 cursor-pointer hover:bg-base-200/30 rounded px-2 py-1 -mx-2 -my-1 transition-colors"
          phx-click="edit_section"
          phx-value-section-id={@node.section.id}
        >
          {LiteskillWeb.Markdown.render(@node.section.content)}
        </div>
      <% end %>

      <div :if={!@editing? && @node.section.comments != []} class="mt-2 space-y-1">
        <.section_comment :for={comment <- @node.section.comments} comment={comment} />
      </div>

      <form :if={!@editing?} phx-submit="add_section_comment" class="mt-2 flex gap-2">
        <input type="hidden" name="section_id" value={@node.section.id} />
        <input
          type="text"
          name="body"
          placeholder="Add a comment..."
          class="input input-bordered input-sm flex-1"
        />
        <button type="submit" class="btn btn-sm btn-ghost">Comment</button>
      </form>

      <div :if={@node.children != []} class="ml-4 mt-2">
        <.section_node
          :for={child <- @node.children}
          node={child}
          depth={@depth + 1}
          editing_section_id={@editing_section_id}
        />
      </div>
    </div>
    """
  end

  defp heading_tag(1), do: "h1"
  defp heading_tag(2), do: "h2"
  defp heading_tag(3), do: "h3"
  defp heading_tag(_), do: "h4"

  defp heading_class(1), do: "text-xl"
  defp heading_class(2), do: "text-lg"
  defp heading_class(3), do: "text-base"
  defp heading_class(_), do: "text-sm"

  attr :comment, :map, required: true

  def section_comment(assigns) do
    replies = if is_list(assigns.comment.replies), do: assigns.comment.replies, else: []
    assigns = assign(assigns, :replies, replies)

    ~H"""
    <div class={[
      "text-sm px-3 py-1.5 rounded",
      if(@comment.status == "addressed",
        do: "bg-success/10 border border-success/20",
        else: "bg-warning/10 border border-warning/20"
      )
    ]}>
      <span class="font-medium">
        {if @comment.author_type == "user", do: "You", else: "Agent"}
      </span>
      <span
        :if={@comment.status == "addressed"}
        class="badge badge-xs badge-success ml-1"
      >
        addressed
      </span>
      <span :if={@comment.status == "open"} class="badge badge-xs badge-warning ml-1">open</span>
      <p class="mt-0.5">{@comment.body}</p>

      <div :if={@replies != []} class="ml-4 mt-1.5 space-y-1">
        <div
          :for={reply <- @replies}
          class="text-xs px-2 py-1 bg-base-200 rounded"
        >
          <span class="font-medium">
            {if reply.author_type == "user", do: "You", else: "Agent"}
          </span>
          <p class="mt-0.5">{reply.body}</p>
        </div>
      </div>

      <form phx-submit="reply_to_comment" class="mt-1.5 flex gap-1">
        <input type="hidden" name="comment_id" value={@comment.id} />
        <input
          type="text"
          name="body"
          placeholder="Reply..."
          class="input input-bordered input-xs flex-1"
        />
        <button type="submit" class="btn btn-xs btn-ghost">Reply</button>
      </form>
    </div>
    """
  end

  # --- Report Card ---

  attr :report, :map, required: true
  attr :owned, :boolean, required: true

  def report_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/reports/#{@report.id}"}
      class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer"
    >
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold text-sm truncate">{@report.title}</h3>
            <p class="text-xs text-base-content/60 mt-0.5">
              {Calendar.strftime(@report.inserted_at, "%b %d, %Y")}
            </p>
          </div>
          <span :if={!@owned} class="badge badge-sm badge-info">shared</span>
        </div>
        <div class="card-actions justify-end mt-2">
          <button
            :if={@owned}
            phx-click="delete_report"
            phx-value-id={@report.id}
            data-confirm="Delete this report and all its sections?"
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-4" /> Delete
          </button>
          <button
            :if={!@owned}
            phx-click="leave_report"
            phx-value-id={@report.id}
            data-confirm="Leave this shared report?"
            class="btn btn-ghost btn-xs text-warning"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> Leave
          </button>
        </div>
      </div>
    </.link>
    """
  end

  # --- RAG Query ---

  attr :show, :boolean, required: true
  attr :collections, :list, required: true
  attr :results, :list, required: true
  attr :loading, :boolean, required: true
  attr :error, :any, required: true

  def rag_query_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id="rag-query-modal"
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={@show && Phoenix.LiveView.JS.focus_first(to: "#rag-query-content")}
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_rag_query" />
      <div
        id="rag-query-content"
        class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-2xl mx-4 max-h-[90vh] flex flex-col"
      >
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">RAG Query</h3>
          <button phx-click="close_rag_query" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>

        <div class="p-4 border-b border-base-300">
          <%= if @collections == [] do %>
            <p class="text-base-content/50 text-sm text-center py-4">
              No RAG collections found. Ingest some documents first.
            </p>
          <% else %>
            <form phx-submit="rag_search" class="space-y-3">
              <div class="form-control">
                <select
                  name="collection_id"
                  class="select select-bordered select-sm w-full"
                >
                  <option :for={coll <- @collections} value={coll.id}>
                    {coll.name}
                  </option>
                </select>
              </div>
              <div class="flex gap-2">
                <input
                  type="text"
                  name="query"
                  placeholder="Enter search query..."
                  class="input input-bordered input-sm flex-1"
                  autocomplete="off"
                />
                <button type="submit" class="btn btn-primary btn-sm" disabled={@loading}>
                  <%= if @loading do %>
                    <span class="loading loading-spinner loading-xs" /> Searching...
                  <% else %>
                    <.icon name="hero-magnifying-glass-micro" class="size-4" /> Search
                  <% end %>
                </button>
              </div>
            </form>
          <% end %>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <div :if={@error} class="alert alert-error text-sm">
            {@error}
          </div>

          <div :if={@loading} class="text-center py-8 text-base-content/50">
            <span class="loading loading-spinner loading-md" />
            <p class="mt-2 text-sm">Embedding query and searching...</p>
          </div>

          <div
            :if={!@loading && @results == [] && !@error}
            class="text-center py-8 text-base-content/50 text-sm"
          >
            Enter a query to search your RAG collections.
          </div>

          <div :if={!@loading && @results != []} class="space-y-2">
            <p class="text-xs text-base-content/50 font-medium">
              {length(@results)} results
            </p>

            <.rag_result_card
              :for={{result, idx} <- Enum.with_index(@results)}
              result={result}
              rank={idx + 1}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :rank, :integer, required: true

  def rag_result_card(assigns) do
    ~H"""
    <div class="border border-base-300 rounded-lg overflow-hidden">
      <div class="flex items-center justify-between px-3 py-2 bg-base-200/50 text-xs">
        <div class="flex items-center gap-2">
          <span class="badge badge-sm badge-primary font-mono">#{@rank}</span>
          <span class="font-medium text-base-content/70">
            {if @result.chunk.document, do: @result.chunk.document.title, else: "Unknown"}
          </span>
          <span :if={source_name(@result)} class="text-base-content/50">
            via {source_name(@result)}
          </span>
        </div>
        <span :if={@result.relevance_score} class="font-mono text-base-content/60">
          {Float.round(@result.relevance_score * 100, 1)}%
        </span>
      </div>
      <div class="px-3 py-2">
        <pre class="text-xs text-base-content/80 whitespace-pre-wrap font-mono leading-relaxed max-h-48 overflow-y-auto">{@result.chunk.content}</pre>
      </div>
      <div class="px-3 py-1.5 bg-base-200/30 text-[10px] text-base-content/40 flex gap-3">
        <span>Position: {@result.chunk.position}</span>
        <span :if={@result.chunk.token_count}>Tokens: {@result.chunk.token_count}</span>
      </div>
    </div>
    """
  end

  defp source_name(%{chunk: %{document: %{source: %{name: name}}}}), do: name
  defp source_name(_), do: nil

  # --- Sources UI ---

  attr :message, :map, required: true

  def sources_button(assigns) do
    has_sources =
      assigns.message.role == "assistant" &&
        assigns.message.content not in [nil, ""] &&
        assigns.message.rag_sources not in [nil, []]

    assigns = assign(assigns, :has_sources, has_sources)
    count = if has_sources, do: length(assigns.message.rag_sources), else: 0
    assigns = assign(assigns, :count, count)

    ~H"""
    <div
      :if={@has_sources}
      class="flex justify-start mb-4"
    >
      <button
        phx-click="toggle_sources_sidebar"
        phx-value-message-id={@message.id}
        class="btn btn-ghost btn-xs gap-1 text-base-content/50 hover:text-primary"
      >
        <.icon name="hero-document-text-micro" class="size-3.5" /> Sources ({@count})
      </button>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :sources, :list, required: true

  def sources_sidebar(assigns) do
    deduped =
      assigns.sources
      |> Enum.uniq_by(fn s -> s["document_id"] end)

    assigns = assign(assigns, :deduped, deduped)

    ~H"""
    <aside
      :if={@show}
      class="w-80 flex-shrink-0 border-l border-base-300 bg-base-100 flex flex-col overflow-hidden"
    >
      <div class="flex items-center justify-between p-3 border-b border-base-300">
        <h3 class="font-semibold text-sm">Sources</h3>
        <button phx-click="close_sources_sidebar" class="btn btn-ghost btn-sm btn-square">
          <.icon name="hero-x-mark-micro" class="size-5" />
        </button>
      </div>
      <div class="flex-1 overflow-y-auto p-3 space-y-2">
        <.source_item
          :for={{source, idx} <- Enum.with_index(@deduped)}
          source={source}
          rank={idx + 1}
        />
      </div>
    </aside>
    """
  end

  attr :source, :map, required: true
  attr :rank, :integer, required: true

  def source_item(assigns) do
    ~H"""
    <button
      phx-click="show_source_modal"
      phx-value-chunk-id={@source["chunk_id"]}
      data-doc-id={@source["document_id"]}
      class="source-item w-full text-left border border-base-300 rounded-lg p-2 hover:border-primary/40 transition-colors cursor-pointer"
    >
      <div class="flex items-center gap-2">
        <span class="badge badge-sm badge-primary font-mono">#{@rank}</span>
        <span class="text-xs font-medium truncate">{@source["document_title"]}</span>
      </div>
      <p class="text-xs text-base-content/60 mt-1 line-clamp-2">
        {String.slice(@source["content"] || "", 0..120)}
      </p>
      <div class="flex items-center gap-2 mt-1 text-[10px] text-base-content/40">
        <span :if={@source["source_name"]}>via {@source["source_name"]}</span>
        <span :if={@source["relevance_score"]}>
          {Float.round(@source["relevance_score"] * 100, 1)}%
        </span>
      </div>
    </button>
    """
  end

  attr :show, :boolean, required: true
  attr :source, :map, required: true

  def source_detail_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_source_modal"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_source_modal" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-2xl max-h-[80vh] flex flex-col z-10 mx-4">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="font-semibold text-sm truncate pr-4">
            {@source["document_title"] || "Source"}
          </h3>
          <button phx-click="close_source_modal" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <div class="bg-base-200/50 rounded-lg p-3">
            <pre class="text-xs whitespace-pre-wrap font-mono leading-relaxed">{@source["content"]}</pre>
          </div>
          <div class="flex items-center gap-3 text-xs text-base-content/50">
            <span :if={@source["source_name"]}>Source: {@source["source_name"]}</span>
            <span :if={@source["position"]}>Position: {@source["position"]}</span>
            <span :if={@source["relevance_score"]}>
              Relevance: {Float.round(@source["relevance_score"] * 100, 1)}%
            </span>
          </div>
        </div>
        <div :if={@source["source_uri"]} class="p-4 border-t border-base-300">
          <.link navigate={@source["source_uri"]} class="btn btn-primary btn-sm w-full gap-1">
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> Go to source document
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
