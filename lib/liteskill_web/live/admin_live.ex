defmodule LiteskillWeb.AdminLive do
  @moduledoc """
  Admin panel components and event handlers, rendered within ChatLive's main area.
  Handles server management, user/group management, LLM providers/models, and usage analytics.
  """

  use LiteskillWeb, :html

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.Groups
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Settings
  alias Liteskill.Usage

  @admin_actions [
    :admin_usage,
    :admin_servers,
    :admin_users,
    :admin_groups,
    :admin_providers,
    :admin_models
  ]

  def admin_action?(action), do: action in @admin_actions

  def admin_assigns do
    [
      profile_users: [],
      profile_groups: [],
      group_detail: nil,
      group_members: [],
      temp_password_user_id: nil,
      llm_models: [],
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      llm_providers: [],
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider),
      server_settings: nil,
      invitations: [],
      new_invitation_url: nil,
      admin_usage_data: %{},
      admin_usage_period: "30d"
    ]
  end

  def apply_admin_action(socket, action, user) do
    if !User.admin?(user) do
      Phoenix.LiveView.push_navigate(socket, to: ~p"/profile")
    else
      load_tab_data(socket, action)
    end
  end

  defp load_tab_data(socket, :admin_usage) do
    period = socket.assigns[:admin_usage_period] || "30d"
    usage_data = load_usage_data(period)

    Phoenix.Component.assign(socket,
      page_title: "Usage Analytics",
      admin_usage_data: usage_data,
      admin_usage_period: period
    )
  end

  defp load_tab_data(socket, :admin_users) do
    Phoenix.Component.assign(socket,
      profile_users: Accounts.list_users(),
      invitations: Accounts.list_invitations(),
      new_invitation_url: nil,
      page_title: "User Management"
    )
  end

  defp load_tab_data(socket, :admin_groups) do
    Phoenix.Component.assign(socket,
      profile_groups: Groups.list_all_groups(),
      page_title: "Group Management"
    )
  end

  defp load_tab_data(socket, :admin_servers) do
    Phoenix.Component.assign(socket,
      page_title: "Server Management",
      server_settings: Settings.get()
    )
  end

  defp load_tab_data(socket, :admin_providers) do
    user_id = socket.assigns.current_user.id

    Phoenix.Component.assign(socket,
      llm_providers: LlmProviders.list_providers(user_id),
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider),
      page_title: "Provider Management"
    )
  end

  defp load_tab_data(socket, :admin_models) do
    user_id = socket.assigns.current_user.id

    Phoenix.Component.assign(socket,
      llm_providers: LlmProviders.list_providers(user_id),
      llm_models: LlmModels.list_models(user_id),
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      page_title: "Model Management"
    )
  end

  defp load_usage_data(period) do
    time_opts = period_to_opts(period)

    instance = Usage.instance_totals(time_opts)
    by_user = Usage.usage_summary(Keyword.merge(time_opts, group_by: :user_id))
    by_model = Usage.usage_summary(Keyword.merge(time_opts, group_by: :model_id))
    daily = Usage.daily_totals(time_opts)

    users = Accounts.list_users()
    user_map = Map.new(users, fn u -> {u.id, u} end)

    groups = Groups.list_all_groups()
    group_ids = Enum.map(groups, & &1.id)
    group_usage_map = Usage.usage_by_groups(group_ids, time_opts)

    group_usage =
      groups
      |> Enum.map(fn group ->
        %{
          group: group,
          usage: Map.get(group_usage_map, group.id, %{total_tokens: 0, call_count: 0})
        }
      end)
      |> Enum.sort_by(fn %{usage: u} -> u.total_tokens end, :desc)

    %{
      instance: instance,
      by_user: by_user,
      by_model: by_model,
      daily: daily,
      user_map: user_map,
      group_usage: group_usage
    }
  end

  defp period_to_opts("7d") do
    [from: DateTime.add(DateTime.utc_now(), -7, :day)]
  end

  defp period_to_opts("30d") do
    [from: DateTime.add(DateTime.utc_now(), -30, :day)]
  end

  defp period_to_opts("90d") do
    [from: DateTime.add(DateTime.utc_now(), -90, :day)]
  end

  defp period_to_opts("all"), do: []

  # --- Public component ---

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, required: true
  attr :profile_users, :list, default: []
  attr :profile_groups, :list, default: []
  attr :group_detail, :any
  attr :group_members, :list, default: []
  attr :temp_password_user_id, :string, default: nil
  attr :llm_models, :list, default: []
  attr :editing_llm_model, :any, default: nil
  attr :llm_model_form, :any
  attr :llm_providers, :list, default: []
  attr :editing_llm_provider, :any, default: nil
  attr :llm_provider_form, :any
  attr :server_settings, :any, default: nil
  attr :invitations, :list, default: []
  attr :new_invitation_url, :string, default: nil
  attr :admin_usage_data, :map, default: %{}
  attr :admin_usage_period, :string, default: "30d"

  def admin_panel(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center gap-2">
        <button
          :if={!@sidebar_open}
          phx-click="toggle_sidebar"
          class="btn btn-circle btn-ghost btn-sm"
        >
          <.icon name="hero-bars-3-micro" class="size-5" />
        </button>
        <h1 class="text-lg font-semibold">Admin</h1>
      </div>
    </header>

    <div class="border-b border-base-300 px-4 flex-shrink-0">
      <div class="flex gap-1 overflow-x-auto" role="tablist">
        <.tab_link
          label="Usage"
          to={~p"/admin/usage"}
          active={@live_action == :admin_usage}
        />
        <.tab_link
          label="Server"
          to={~p"/admin/servers"}
          active={@live_action == :admin_servers}
        />
        <.tab_link
          label="Users"
          to={~p"/admin/users"}
          active={@live_action == :admin_users}
        />
        <.tab_link
          label="Groups"
          to={~p"/admin/groups"}
          active={@live_action == :admin_groups}
        />
        <.tab_link
          label="Providers"
          to={~p"/admin/providers"}
          active={@live_action == :admin_providers}
        />
        <.tab_link
          label="Models"
          to={~p"/admin/models"}
          active={@live_action == :admin_models}
        />
      </div>
    </div>

    <div class="flex-1 overflow-y-auto p-6">
      <div class={[
        "mx-auto",
        if(
          @live_action in [:admin_providers, :admin_models, :admin_users, :admin_groups, :admin_usage],
          do: "max-w-6xl",
          else: "max-w-3xl"
        )
      ]}>
        {render_tab(assigns)}
      </div>
    </div>
    """
  end

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "tab tab-bordered whitespace-nowrap",
        @active && "tab-active"
      ]}
    >
      {@label}
    </.link>
    """
  end

  # --- Usage Tab ---

  defp render_tab(%{live_action: :admin_usage} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Usage Analytics</h2>
        <div class="flex gap-1">
          <button
            :for={
              {label, value} <- [
                {"7 days", "7d"},
                {"30 days", "30d"},
                {"90 days", "90d"},
                {"All time", "all"}
              ]
            }
            phx-click="admin_usage_period"
            phx-value-period={value}
            class={[
              "btn btn-sm",
              if(@admin_usage_period == value, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <.usage_instance_summary usage={@admin_usage_data[:instance]} />
      <.usage_daily_chart daily={@admin_usage_data[:daily] || []} />
      <.usage_by_model data={@admin_usage_data[:by_model] || []} />
      <.usage_by_user
        data={@admin_usage_data[:by_user] || []}
        user_map={@admin_usage_data[:user_map] || %{}}
      />
      <.usage_by_group data={@admin_usage_data[:group_usage] || []} />
    </div>
    """
  end

  # --- Server Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_servers} = assigns) do
    repo_config = Liteskill.Repo.config()
    oban_config = Application.get_env(:liteskill, Oban, [])
    oidc_config = Application.get_env(:ueberauth, Ueberauth.Strategy.OIDCC, [])

    assigns =
      assigns
      |> assign(:repo_config, repo_config)
      |> assign(:oban_config, oban_config)
      |> assign(:oidc_config, oidc_config)

    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Registration</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Public Registration</p>
              <p class="text-sm text-base-content/60">
                {if @server_settings && @server_settings.registration_open,
                  do: "Anyone can create an account",
                  else: "Only invited users can create accounts"}
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@server_settings && @server_settings.registration_open}
              phx-click="toggle_registration"
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Database</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Host" value={to_string(@repo_config[:hostname] || "—")} />
            <.info_row label="Port" value={to_string(@repo_config[:port] || 5432)} />
            <.info_row label="Database" value={to_string(@repo_config[:database] || "—")} />
            <.info_row label="Pool Size" value={to_string(@repo_config[:pool_size] || "—")} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">OIDC / SSO</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Issuer" value={@oidc_config[:issuer] || "Not configured"} />
            <.info_row label="Client ID" value={@oidc_config[:client_id] || "Not configured"} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Job Queues (Oban)</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <%= for {queue, limit} <- @oban_config[:queues] || [] do %>
              <.info_row label={to_string(queue)} value={"Concurrency: #{limit}"} />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- User Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_users} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Invite User</h2>
          <form phx-submit="create_invitation" class="flex gap-2 items-end">
            <div class="form-control flex-1">
              <input
                type="email"
                name="email"
                placeholder="user@example.com"
                class="input input-bordered input-sm w-full"
                required
              />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Send Invite</button>
          </form>
          <div
            :if={@new_invitation_url}
            class="alert alert-success mt-3"
          >
            <div class="flex-1">
              <p class="font-medium text-sm">Invitation created! Share this link:</p>
              <div class="flex items-center gap-2 mt-1">
                <code class="text-xs break-all flex-1" id="invite-url">{@new_invitation_url}</code>
                <button
                  phx-click={Phoenix.LiveView.JS.dispatch("phx:copy", to: "#invite-url")}
                  class="btn btn-ghost btn-xs"
                >
                  Copy
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@invitations != []} class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Pending Invitations</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Invited By</th>
                  <th>Expires</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for inv <- @invitations do %>
                  <tr>
                    <td class="font-mono text-sm">{inv.email}</td>
                    <td class="text-sm text-base-content/60">
                      {inv.created_by && inv.created_by.email}
                    </td>
                    <td class="text-sm text-base-content/60">
                      {Calendar.strftime(inv.expires_at, "%Y-%m-%d %H:%M")}
                    </td>
                    <td>{invitation_status_badge(inv)}</td>
                    <td>
                      <button
                        :if={!Liteskill.Accounts.Invitation.used?(inv)}
                        phx-click="revoke_invitation"
                        phx-value-id={inv.id}
                        data-confirm="Revoke this invitation?"
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">User Management</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                  <th>Source</th>
                  <th>Role</th>
                  <th>Created</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for user <- @profile_users do %>
                  <tr>
                    <td>{user.name || "—"}</td>
                    <td class="font-mono text-sm">{user.email}</td>
                    <td>{sign_on_source(user)}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        User.admin?(user) && "badge-primary",
                        !User.admin?(user) && "badge-neutral"
                      ]}>
                        {String.capitalize(user.role)}
                      </span>
                    </td>
                    <td class="text-sm text-base-content/60">
                      {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
                    </td>
                    <td class="flex gap-1">
                      <%= if user.email != User.admin_email() do %>
                        <%= if User.admin?(user) do %>
                          <button
                            phx-click="demote_user"
                            phx-value-id={user.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Demote
                          </button>
                        <% else %>
                          <button
                            phx-click="promote_user"
                            phx-value-id={user.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Promote
                          </button>
                        <% end %>
                        <button
                          phx-click="show_temp_password_form"
                          phx-value-id={user.id}
                          class="btn btn-ghost btn-xs"
                        >
                          Set Password
                        </button>
                      <% else %>
                        <span class="text-xs text-base-content/40">Root</span>
                      <% end %>
                    </td>
                  </tr>
                  <tr :if={@temp_password_user_id == user.id}>
                    <td colspan="6">
                      <form
                        phx-submit="set_temp_password"
                        class="flex items-center gap-2 py-2"
                      >
                        <input type="hidden" name="user_id" value={user.id} />
                        <span class="text-sm">
                          Set temporary password for <strong>{user.email}</strong>:
                        </span>
                        <input
                          type="password"
                          name="password"
                          placeholder="Min 12 characters"
                          class="input input-bordered input-sm w-48"
                          required
                          minlength="12"
                        />
                        <button type="submit" class="btn btn-primary btn-sm">Set</button>
                        <button
                          type="button"
                          phx-click="cancel_temp_password"
                          class="btn btn-ghost btn-sm"
                        >
                          Cancel
                        </button>
                      </form>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Group Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_groups} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Groups</h2>
            <form phx-submit="create_group" class="flex gap-2">
              <input
                type="text"
                name="name"
                placeholder="New group name"
                class="input input-bordered input-sm"
                required
              />
              <button type="submit" class="btn btn-primary btn-sm">Create</button>
            </form>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Members</th>
                  <th>Created By</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for group <- @profile_groups do %>
                  <tr>
                    <td>{group.name}</td>
                    <td>{length(group.memberships)}</td>
                    <td class="text-sm text-base-content/60">
                      {group.creator && group.creator.email}
                    </td>
                    <td class="flex gap-1">
                      <button
                        phx-click="view_group"
                        phx-value-id={group.id}
                        class="btn btn-ghost btn-xs"
                      >
                        View
                      </button>
                      <button
                        phx-click="admin_delete_group"
                        phx-value-id={group.id}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Delete
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div :if={@group_detail} class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{@group_detail.name} — Members</h2>
            <form phx-submit="admin_add_member" class="flex gap-2">
              <input
                type="email"
                name="email"
                placeholder="User email"
                class="input input-bordered input-sm"
                required
              />
              <button type="submit" class="btn btn-primary btn-sm">Add</button>
            </form>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Role</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for member <- @group_members do %>
                  <tr>
                    <td>{member.user.email}</td>
                    <td>
                      <span class="badge badge-sm badge-neutral">{member.role}</span>
                    </td>
                    <td>
                      <button
                        phx-click="admin_remove_member"
                        phx-value-user-id={member.user_id}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Remove
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Provider Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_providers} = assigns) do
    provider_types = LlmProvider.valid_provider_types()
    assigns = assign(assigns, :provider_types, provider_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Providers</h2>
          <button
            :if={!@editing_llm_provider}
            phx-click="new_llm_provider"
            class="btn btn-primary btn-sm"
          >
            Add Provider
          </button>
        </div>

        <div :if={@editing_llm_provider} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @editing_llm_provider == :new, do: "Add New Provider", else: "Edit Provider"}
          </h3>
          <.form
            for={@llm_provider_form}
            phx-submit={
              if @editing_llm_provider == :new,
                do: "create_llm_provider",
                else: "update_llm_provider"
            }
            class="space-y-3"
          >
            <input
              :if={@editing_llm_provider != :new}
              type="hidden"
              name="llm_provider[id]"
              value={@editing_llm_provider}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name="llm_provider[name]"
                  value={@llm_provider_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="AWS Bedrock US-East"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider Type</span></label>
                <select
                  name="llm_provider[provider_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for pt <- @provider_types do %>
                    <option
                      value={pt}
                      selected={@llm_provider_form[:provider_type].value == pt}
                    >
                      {pt}
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">API Key</span></label>
                <input
                  type="password"
                  name="llm_provider[api_key]"
                  value={@llm_provider_form[:api_key].value}
                  class="input input-bordered input-sm w-full"
                  placeholder="Optional — encrypted at rest"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Status</span></label>
                <select
                  name="llm_provider[status]"
                  class="select select-bordered select-sm w-full"
                >
                  <option
                    value="active"
                    selected={@llm_provider_form[:status].value != "inactive"}
                  >
                    Active
                  </option>
                  <option
                    value="inactive"
                    selected={@llm_provider_form[:status].value == "inactive"}
                  >
                    Inactive
                  </option>
                </select>
              </div>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Provider Config (JSON)</span>
              </label>
              <textarea
                name="llm_provider[provider_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"region": "us-east-1"}'
              >{@llm_provider_form[:provider_config_json] && @llm_provider_form[:provider_config_json].value}</textarea>
            </div>
            <label class="label cursor-pointer gap-2 w-fit">
              <input
                type="checkbox"
                name="llm_provider[instance_wide]"
                value="true"
                checked={@llm_provider_form[:instance_wide].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Instance-wide (all users)</span>
            </label>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                phx-click="cancel_llm_provider"
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
                <th>Scope</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for provider <- @llm_providers do %>
                <tr>
                  <td class="font-medium">{provider.name}</td>
                  <td>
                    <span class="badge badge-sm badge-neutral">{provider.provider_type}</span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      provider.instance_wide && "badge-primary",
                      !provider.instance_wide && "badge-outline"
                    ]}>
                      {if provider.instance_wide, do: "Instance", else: "Scoped"}
                    </span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      provider.status == "active" && "badge-success",
                      provider.status == "inactive" && "badge-warning"
                    ]}>
                      {provider.status}
                    </span>
                  </td>
                  <td class="flex gap-1">
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="llm_provider"
                      phx-value-entity-id={provider.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Share
                    </button>
                    <button
                      phx-click="edit_llm_provider"
                      phx-value-id={provider.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_llm_provider"
                      phx-value-id={provider.id}
                      data-confirm="Delete this provider? Models using it must be reassigned first."
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@llm_providers == []} class="text-base-content/60 text-center py-4">
            No providers configured. Add one to get started.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # --- Model Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_models} = assigns) do
    model_types = Liteskill.LlmModels.LlmModel.valid_model_types()
    assigns = assign(assigns, :model_types, model_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Models</h2>
          <button
            :if={!@editing_llm_model && @llm_providers != []}
            phx-click="new_llm_model"
            class="btn btn-primary btn-sm"
          >
            Add Model
          </button>
        </div>

        <div :if={@editing_llm_model} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @editing_llm_model == :new, do: "Add New Model", else: "Edit Model"}
          </h3>
          <.form
            for={@llm_model_form}
            phx-submit={
              if @editing_llm_model == :new, do: "create_llm_model", else: "update_llm_model"
            }
            class="space-y-3"
          >
            <input
              :if={@editing_llm_model != :new}
              type="hidden"
              name="llm_model[id]"
              value={@editing_llm_model}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Display Name</span></label>
                <input
                  type="text"
                  name="llm_model[name]"
                  value={@llm_model_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="Claude Sonnet (US East)"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider</span></label>
                <select
                  name="llm_model[provider_id]"
                  class="select select-bordered select-sm w-full"
                  required
                >
                  <%= for p <- @llm_providers do %>
                    <option
                      value={p.id}
                      selected={@llm_model_form[:provider_id].value == p.id}
                    >
                      {p.name} ({p.provider_type})
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Model ID</span></label>
                <input
                  type="text"
                  name="llm_model[model_id]"
                  value={@llm_model_form[:model_id].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="us.anthropic.claude-3-5-sonnet-20241022-v2:0"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Model Type</span></label>
                <select
                  name="llm_model[model_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for mt <- @model_types do %>
                    <option
                      value={mt}
                      selected={@llm_model_form[:model_type].value == mt}
                    >
                      {mt}
                    </option>
                  <% end %>
                </select>
              </div>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Input Cost / 1M tokens ($)</span>
                </label>
                <input
                  type="number"
                  name="llm_model[input_cost_per_million]"
                  value={
                    @llm_model_form[:input_cost_per_million] &&
                      @llm_model_form[:input_cost_per_million].value
                  }
                  class="input input-bordered input-sm w-full"
                  step="0.01"
                  min="0"
                  placeholder="3.00"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Output Cost / 1M tokens ($)</span>
                </label>
                <input
                  type="number"
                  name="llm_model[output_cost_per_million]"
                  value={
                    @llm_model_form[:output_cost_per_million] &&
                      @llm_model_form[:output_cost_per_million].value
                  }
                  class="input input-bordered input-sm w-full"
                  step="0.01"
                  min="0"
                  placeholder="15.00"
                />
              </div>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Model Config (JSON)</span>
              </label>
              <textarea
                name="llm_model[model_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"max_tokens": 4096}'
              >{@llm_model_form[:model_config_json] && @llm_model_form[:model_config_json].value}</textarea>
            </div>
            <div class="flex items-center gap-4">
              <label class="label cursor-pointer gap-2">
                <input
                  type="checkbox"
                  name="llm_model[instance_wide]"
                  value="true"
                  checked={@llm_model_form[:instance_wide].value == "true"}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">Instance-wide (all users)</span>
              </label>
              <select
                name="llm_model[status]"
                class="select select-bordered select-sm"
              >
                <option value="active" selected={@llm_model_form[:status].value != "inactive"}>
                  Active
                </option>
                <option value="inactive" selected={@llm_model_form[:status].value == "inactive"}>
                  Inactive
                </option>
              </select>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" phx-click="cancel_llm_model" class="btn btn-ghost btn-sm">
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Provider</th>
                <th>Model ID</th>
                <th>Type</th>
                <th>Pricing (per 1M)</th>
                <th>Scope</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for model <- @llm_models do %>
                <tr>
                  <td class="font-medium">{model.name}</td>
                  <td>
                    <span class="badge badge-sm badge-neutral">
                      {model.provider && model.provider.name}
                    </span>
                  </td>
                  <td class="font-mono text-sm max-w-xs truncate">{model.model_id}</td>
                  <td><span class="badge badge-sm badge-ghost">{model.model_type}</span></td>
                  <td class="text-sm">
                    <%= if model.input_cost_per_million || model.output_cost_per_million do %>
                      <span class="text-base-content/60">In:</span>
                      ${format_decimal(model.input_cost_per_million)}
                      <span class="text-base-content/40 mx-1">/</span>
                      <span class="text-base-content/60">Out:</span>
                      ${format_decimal(model.output_cost_per_million)}
                    <% else %>
                      <span class="text-base-content/40">—</span>
                    <% end %>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      model.instance_wide && "badge-primary",
                      !model.instance_wide && "badge-outline"
                    ]}>
                      {if model.instance_wide, do: "Instance", else: "Scoped"}
                    </span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      model.status == "active" && "badge-success",
                      model.status == "inactive" && "badge-warning"
                    ]}>
                      {model.status}
                    </span>
                  </td>
                  <td class="flex gap-1">
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="llm_model"
                      phx-value-entity-id={model.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Share
                    </button>
                    <button
                      phx-click="edit_llm_model"
                      phx-value-id={model.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_llm_model"
                      phx-value-id={model.id}
                      data-confirm="Delete this model configuration?"
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@llm_models == []} class="text-base-content/60 text-center py-4">
            {if @llm_providers == [],
              do: "Add a provider first, then configure models.",
              else: "No models configured. Add one to get started."}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # --- Usage Sub-Components ---

  defp usage_instance_summary(assigns) do
    usage = assigns[:usage] || %{}
    assigns = assign(assigns, :usage, usage)

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card label="Total Cost" value={format_cost(@usage[:total_cost])} />
      <.stat_card label="Input Cost" value={format_cost(@usage[:input_cost])} />
      <.stat_card label="Output Cost" value={format_cost(@usage[:output_cost])} />
      <.stat_card label="API Calls" value={format_number(@usage[:call_count] || 0)} />
      <.stat_card label="Total Tokens" value={format_number(@usage[:total_tokens] || 0)} />
      <.stat_card label="Input Tokens" value={format_number(@usage[:input_tokens] || 0)} />
      <.stat_card label="Output Tokens" value={format_number(@usage[:output_tokens] || 0)} />
      <.stat_card label="Reasoning Tokens" value={format_number(@usage[:reasoning_tokens] || 0)} />
      <.stat_card label="Cached Tokens" value={format_number(@usage[:cached_tokens] || 0)} />
      <.stat_card
        label="Cache Hit Rate"
        value={format_percentage(@usage[:cached_tokens] || 0, @usage[:input_tokens] || 0)}
      />
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-4">
        <div class="text-sm text-base-content/60">{@label}</div>
        <div class="text-2xl font-bold">{@value}</div>
      </div>
    </div>
    """
  end

  defp usage_daily_chart(assigns) do
    ~H"""
    <div :if={@daily != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Daily Usage</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Date</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Volume</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @daily}>
                <td class="font-mono text-sm">{format_date(day.date)}</td>
                <td class="text-right">{format_number(day.total_tokens)}</td>
                <td class="text-right">{format_cost(day.input_cost)}</td>
                <td class="text-right">{format_cost(day.output_cost)}</td>
                <td class="text-right">{format_cost(day.total_cost)}</td>
                <td class="text-right">{day.call_count}</td>
                <td>
                  <div class="w-32 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-primary h-2 rounded-full"
                      style={"width: #{bar_width(day.total_tokens, @daily)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_model(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Model</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Model</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-mono text-sm max-w-xs truncate">{row.model_id}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-secondary h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_user(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by User</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- Enum.sort_by(@data, & &1.total_tokens, :desc)}>
                <td>
                  <span :if={@user_map[row.user_id]} class="text-sm">
                    {@user_map[row.user_id].email}
                  </span>
                  <span :if={!@user_map[row.user_id]} class="text-sm text-base-content/50">
                    Unknown
                  </span>
                </td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-accent h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_group(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Group</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Group</th>
                <th class="text-right">Members</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{group: group, usage: usage} <- @data}>
                <td class="font-medium">{group.name}</td>
                <td class="text-right">{length(group.memberships)}</td>
                <td class="text-right">{format_number(usage.total_tokens)}</td>
                <td class="text-right">{format_cost(usage.input_cost)}</td>
                <td class="text-right">{format_cost(usage.output_cost)}</td>
                <td class="text-right">{format_cost(usage.total_cost)}</td>
                <td class="text-right">{usage.call_count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp info_row(assigns) do
    ~H"""
    <div>
      <div class="text-sm text-base-content/60 mb-1">{@label}</div>
      <div class="font-medium">{@value}</div>
    </div>
    """
  end

  defp sign_on_source(%User{oidc_sub: nil}), do: "Local (password)"
  defp sign_on_source(%User{oidc_issuer: issuer}), do: "SSO (#{issuer})"

  defp invitation_status_badge(inv) do
    alias Liteskill.Accounts.Invitation

    cond do
      Invitation.used?(inv) ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-success">Used</span>))

      Invitation.expired?(inv) ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-warning">Expired</span>))

      true ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-info">Pending</span>))
    end
  end

  defp format_cost(nil), do: "$0.00"

  defp format_cost(%Decimal{} = d) do
    "$#{Decimal.round(d, 4)}"
  end

  defp format_cost(_), do: "$0.00"

  defp format_decimal(nil), do: "0.00"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2))
  defp format_decimal(_), do: "0.00"

  defp format_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(_), do: "0"

  defp format_percentage(_, 0), do: "—"
  defp format_percentage(part, whole), do: "#{Float.round(part / whole * 100, 1)}%"

  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(_), do: "—"

  defp bar_width(_tokens, []), do: 0

  defp bar_width(tokens, daily) do
    max = daily |> Enum.map(& &1.total_tokens) |> Enum.max(fn -> 1 end)
    if max == 0, do: 0, else: Float.round(tokens / max * 100, 0)
  end

  defp token_share(_tokens, []), do: 0

  defp token_share(tokens, data) do
    total = data |> Enum.map(& &1.total_tokens) |> Enum.sum()
    if total == 0, do: 0, else: Float.round(tokens / total * 100, 0)
  end

  # --- Event Handlers (called from ChatLive) ---

  defp require_admin(socket, fun) do
    if User.admin?(socket.assigns.current_user) do
      fun.()
    else
      {:noreply, socket}
    end
  end

  def handle_event("admin_usage_period", %{"period" => period}, socket) do
    require_admin(socket, fn ->
      usage_data = load_usage_data(period)

      {:noreply,
       Phoenix.Component.assign(socket,
         admin_usage_data: usage_data,
         admin_usage_period: period
       )}
    end)
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "admin")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "user")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      Groups.create_group(name, user_id)
      {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("admin_delete_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Groups.admin_delete_group(id)

      socket =
        if socket.assigns.group_detail && socket.assigns.group_detail.id == id do
          Phoenix.Component.assign(socket, group_detail: nil, group_members: [])
        else
          socket
        end

      {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("view_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Groups.admin_get_group(id) do
        {:ok, group} ->
          members = Groups.admin_list_members(id)

          {:noreply,
           Phoenix.Component.assign(socket, group_detail: group, group_members: members)}

        {:error, _} ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("admin_add_member", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      group = socket.assigns.group_detail

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "User not found")}

        user ->
          case Groups.admin_add_member(group.id, user.id, "member") do
            {:ok, _} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 group_members: Groups.admin_list_members(group.id)
               )}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to add member")}
          end
      end
    end)
  end

  def handle_event("admin_remove_member", %{"user-id" => user_id}, socket) do
    require_admin(socket, fn ->
      group = socket.assigns.group_detail
      Groups.admin_remove_member(group.id, user_id)

      {:noreply,
       Phoenix.Component.assign(socket, group_members: Groups.admin_list_members(group.id))}
    end)
  end

  def handle_event("show_temp_password_form", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, temp_password_user_id: id)}
  end

  def handle_event("cancel_temp_password", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, temp_password_user_id: nil)}
  end

  def handle_event("set_temp_password", %{"user_id" => id, "password" => password}, socket) do
    require_admin(socket, fn ->
      user = Accounts.get_user!(id)

      case Accounts.set_temporary_password(user, password) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             temp_password_user_id: nil,
             profile_users: Accounts.list_users()
           )
           |> Phoenix.LiveView.put_flash(
             :info,
             "Temporary password set. User must change it on next login."
           )}

        {:error, _} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             "Failed to set password. Ensure it is at least 12 characters."
           )}
      end
    end)
  end

  # --- Registration & Invitation event handlers ---

  def handle_event("toggle_registration", _params, socket) do
    require_admin(socket, fn ->
      case Settings.toggle_registration() do
        {:ok, settings} ->
          {:noreply, Phoenix.Component.assign(socket, server_settings: settings)}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to toggle registration")}
      end
    end)
  end

  def handle_event("create_invitation", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      case Accounts.create_invitation(email, socket.assigns.current_user.id) do
        {:ok, invitation} ->
          url = LiteskillWeb.Endpoint.url() <> "/invite/#{invitation.token}"

          {:noreply,
           socket
           |> Phoenix.Component.assign(
             invitations: Accounts.list_invitations(),
             new_invitation_url: url
           )
           |> Phoenix.LiveView.put_flash(:info, "Invitation created")}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to create invitation")}
      end
    end)
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Accounts.revoke_invitation(id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(invitations: Accounts.list_invitations())
           |> Phoenix.LiveView.put_flash(:info, "Invitation revoked")}

        {:error, :already_used} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, "Cannot revoke a used invitation")}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to revoke invitation")}
      end
    end)
  end

  # --- LLM Provider event handlers ---

  def handle_event("new_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket,
         editing_llm_provider: :new,
         llm_provider_form: to_form(%{}, as: :llm_provider)
       )}
    end)
  end

  def handle_event("cancel_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, editing_llm_provider: nil)}
    end)
  end

  def handle_event("create_llm_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_provider_attrs(params, socket.assigns.current_user.id),
           {:ok, _provider} <- LlmProviders.create_provider(attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
           editing_llm_provider: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Provider created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to create provider")}
      end
    end)
  end

  def handle_event("edit_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.get_provider(id, socket.assigns.current_user.id) do
        {:ok, provider} ->
          config_json =
            if provider.provider_config && provider.provider_config != %{},
              do: Jason.encode!(provider.provider_config),
              else: ""

          form_data = %{
            "name" => provider.name,
            "provider_type" => provider.provider_type,
            "api_key" => "",
            "provider_config_json" => config_json,
            "instance_wide" => if(provider.instance_wide, do: "true", else: "false"),
            "status" => provider.status
          }

          {:noreply,
           Phoenix.Component.assign(socket,
             editing_llm_provider: id,
             llm_provider_form: to_form(form_data, as: :llm_provider)
           )}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Provider not found")}
      end
    end)
  end

  def handle_event("update_llm_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      id = params["id"]

      with {:ok, attrs} <- build_provider_attrs(params, socket.assigns.current_user.id),
           {:ok, _provider} <-
             LlmProviders.update_provider(id, socket.assigns.current_user.id, attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
           editing_llm_provider: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Provider updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to update provider")}
      end
    end)
  end

  def handle_event("delete_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.delete_provider(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
             editing_llm_provider: nil
           )
           |> Phoenix.LiveView.put_flash(:info, "Provider deleted")}

        {:error, _} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             "Failed to delete provider. Remove its models first."
           )}
      end
    end)
  end

  # --- LLM Model event handlers ---

  def handle_event("new_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket,
         editing_llm_model: :new,
         llm_model_form: to_form(%{}, as: :llm_model)
       )}
    end)
  end

  def handle_event("cancel_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, editing_llm_model: nil)}
    end)
  end

  def handle_event("create_llm_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_model_attrs(params, socket.assigns.current_user.id),
           {:ok, _model} <- LlmModels.create_model(attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_models: LlmModels.list_models(socket.assigns.current_user.id),
           editing_llm_model: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Model created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to create model")}
      end
    end)
  end

  def handle_event("edit_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.get_model(id, socket.assigns.current_user.id) do
        {:ok, model} ->
          config_json =
            if model.model_config && model.model_config != %{},
              do: Jason.encode!(model.model_config),
              else: ""

          form_data = %{
            "name" => model.name,
            "provider_id" => model.provider_id,
            "model_id" => model.model_id,
            "model_type" => model.model_type,
            "model_config_json" => config_json,
            "instance_wide" => if(model.instance_wide, do: "true", else: "false"),
            "status" => model.status,
            "input_cost_per_million" => format_decimal(model.input_cost_per_million),
            "output_cost_per_million" => format_decimal(model.output_cost_per_million)
          }

          {:noreply,
           Phoenix.Component.assign(socket,
             editing_llm_model: id,
             llm_model_form: to_form(form_data, as: :llm_model)
           )}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Model not found")}
      end
    end)
  end

  def handle_event("update_llm_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      id = params["id"]

      with {:ok, attrs} <- build_model_attrs(params, socket.assigns.current_user.id),
           {:ok, _model} <- LlmModels.update_model(id, socket.assigns.current_user.id, attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_models: LlmModels.list_models(socket.assigns.current_user.id),
           editing_llm_model: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Model updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to update model")}
      end
    end)
  end

  def handle_event("delete_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.delete_model(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             llm_models: LlmModels.list_models(socket.assigns.current_user.id),
             editing_llm_model: nil
           )
           |> Phoenix.LiveView.put_flash(:info, "Model deleted")}

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to delete model")}
      end
    end)
  end

  defp build_provider_attrs(params, user_id) do
    with {:ok, provider_config} <- parse_json_config(params["provider_config_json"]) do
      attrs = %{
        name: params["name"],
        provider_type: params["provider_type"],
        provider_config: provider_config,
        instance_wide: params["instance_wide"] == "true",
        status: params["status"] || "active",
        user_id: user_id
      }

      attrs =
        case params["api_key"] do
          nil -> attrs
          "" -> attrs
          key -> Map.put(attrs, :api_key, key)
        end

      {:ok, attrs}
    end
  end

  defp build_model_attrs(params, user_id) do
    with {:ok, model_config} <- parse_json_config(params["model_config_json"]) do
      {:ok,
       %{
         name: params["name"],
         provider_id: params["provider_id"],
         model_id: params["model_id"],
         model_type: params["model_type"] || "inference",
         model_config: model_config,
         instance_wide: params["instance_wide"] == "true",
         status: params["status"] || "active",
         input_cost_per_million: parse_decimal(params["input_cost_per_million"]),
         output_cost_per_million: parse_decimal(params["output_cost_per_million"]),
         user_id: user_id
       }}
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_json_config(nil), do: {:ok, %{}}
  defp parse_json_config(""), do: {:ok, %{}}

  defp parse_json_config(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "Config must be a JSON object, not an array or scalar"}
      {:error, _} -> {:error, "Invalid JSON in config field"}
    end
  end
end
