defmodule LiteskillWeb.SetupLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Initial Setup",
       form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
       error: nil
     ), layout: {LiteskillWeb.Layouts, :root}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <div class="card bg-base-100 shadow-xl w-full max-w-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">Welcome to Liteskill</h2>
          <p class="text-base-content/70">
            Set a password for the admin account to get started.
          </p>

          <.form for={@form} phx-submit="setup" class="mt-4 space-y-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Password</span></label>
              <input
                type="password"
                name="setup[password]"
                value={Phoenix.HTML.Form.input_value(@form, :password)}
                placeholder="Minimum 12 characters"
                class="input input-bordered w-full"
                required
                minlength="12"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Confirm Password</span></label>
              <input
                type="password"
                name="setup[password_confirmation]"
                value={Phoenix.HTML.Form.input_value(@form, :password_confirmation)}
                placeholder="Repeat password"
                class="input input-bordered w-full"
                required
                minlength="12"
              />
            </div>

            <p :if={@error} class="text-error text-sm">{@error}</p>

            <button type="submit" class="btn btn-primary w-full">Set Password & Continue</button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("setup", %{"setup" => params}, socket) do
    password = params["password"]
    confirmation = params["password_confirmation"]

    cond do
      password != confirmation ->
        {:noreply, assign(socket, error: "Passwords do not match")}

      String.length(password) < 12 ->
        {:noreply, assign(socket, error: "Password must be at least 12 characters")}

      true ->
        case Accounts.setup_admin_password(socket.assigns.current_user, password) do
          {:ok, _user} ->
            {:noreply, redirect(socket, to: "/login")}

          {:error, _changeset} ->
            {:noreply, assign(socket, error: "Failed to set password. Please try again.")}
        end
    end
  end
end
