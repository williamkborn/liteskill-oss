defmodule LiteskillWeb.Plugs.LiveAuth do
  @moduledoc """
  LiveView on_mount hooks for authentication.

  Used in live_session to protect LiveView routes.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User

  def on_mount(:require_authenticated, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            {:halt, redirect(socket, to: "/login")}

          user ->
            if User.setup_required?(user) do
              {:halt, redirect(socket, to: "/setup")}
            else
              {:cont, assign(socket, :current_user, user)}
            end
        end
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            {:halt, redirect(socket, to: "/login")}

          user ->
            if User.admin?(user) do
              {:cont, assign(socket, :current_user, user)}
            else
              {:halt, redirect(socket, to: "/")}
            end
        end
    end
  end

  def on_mount(:require_setup_needed, _params, _session, socket) do
    admin = Accounts.get_user_by_email(User.admin_email())

    if admin && User.setup_required?(admin) do
      {:cont, assign(socket, :current_user, admin)}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    # If admin account needs setup, redirect to setup regardless of auth
    admin = Accounts.get_user_by_email(User.admin_email())

    if admin && User.setup_required?(admin) do
      {:halt, redirect(socket, to: "/setup")}
    else
      case session["user_id"] do
        nil ->
          {:cont, assign(socket, :current_user, nil)}

        user_id ->
          case Accounts.get_user(user_id) do
            nil ->
              {:cont, assign(socket, :current_user, nil)}

            _user ->
              {:halt, redirect(socket, to: "/")}
          end
      end
    end
  end
end
