defmodule LiteskillWeb.AuthLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: :user), error: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, error: nil, form: to_form(%{}, as: :user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <div class="card w-full max-w-sm bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl font-bold justify-center mb-2">
            {if @live_action == :register, do: "Create Account", else: "Welcome Back"}
          </h2>

          <.form for={@form} phx-submit="submit" class="space-y-4">
            <div :if={@live_action == :register} class="form-control">
              <label class="label" for="user_name">
                <span class="label-text">Name</span>
              </label>
              <input
                type="text"
                name="user[name]"
                id="user_name"
                value={@form[:name].value}
                class="input input-bordered w-full"
                required
              />
            </div>

            <div class="form-control">
              <label class="label" for="user_email">
                <span class="label-text">Email</span>
              </label>
              <input
                type={if @live_action == :register, do: "email", else: "text"}
                name="user[email]"
                id="user_email"
                value={@form[:email].value}
                placeholder="Email"
                class="input input-bordered w-full"
                required
              />
            </div>

            <div class="form-control">
              <label class="label" for="user_password">
                <span class="label-text">Password</span>
              </label>
              <input
                type="password"
                name="user[password]"
                id="user_password"
                class="input input-bordered w-full"
                required
              />
            </div>

            <p :if={@error} class="text-error text-sm">{@error}</p>

            <div class="form-control mt-6">
              <button type="submit" class="btn btn-primary w-full">
                {if @live_action == :register, do: "Register", else: "Sign In"}
              </button>
            </div>
          </.form>

          <div class="divider">or</div>

          <div class="text-center text-sm">
            <.link
              :if={@live_action == :login}
              navigate={~p"/register"}
              class="link link-primary"
            >
              Create an account
            </.link>
            <.link
              :if={@live_action == :register}
              navigate={~p"/login"}
              class="link link-primary"
            >
              Already have an account? Sign in
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    case socket.assigns.live_action do
      :register -> handle_register(params, socket)
      :login -> handle_login(params, socket)
    end
  end

  defp handle_register(params, socket) do
    attrs = %{
      email: params["email"],
      name: params["name"],
      password: params["password"]
    }

    case Accounts.register_user(attrs) do
      {:ok, user} ->
        token = Phoenix.Token.sign(LiteskillWeb.Endpoint, "user_session", user.id)
        {:noreply, redirect(socket, to: "/auth/session?token=#{token}")}

      {:error, changeset} ->
        error = format_changeset_error(changeset)
        {:noreply, assign(socket, error: error)}
    end
  end

  defp handle_login(params, socket) do
    email = expand_admin_shorthand(params["email"])

    case Accounts.authenticate_by_email_password(email, params["password"]) do
      {:ok, user} ->
        token = Phoenix.Token.sign(LiteskillWeb.Endpoint, "user_session", user.id)
        {:noreply, redirect(socket, to: "/auth/session?token=#{token}")}

      {:error, :invalid_credentials} ->
        {:noreply, assign(socket, error: "Invalid email or password")}
    end
  end

  defp expand_admin_shorthand("admin"), do: Liteskill.Accounts.User.admin_email()
  defp expand_admin_shorthand(email), do: email

  defp format_changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} ->
      "#{field} #{Enum.join(errors, ", ")}"
    end)
  end
end
