defmodule LiteskillWeb.AuthController do
  use LiteskillWeb, :controller

  plug Ueberauth

  alias Liteskill.Accounts

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    user_attrs = %{
      email: auth.info.email,
      name: auth.info.name,
      avatar_url: auth.info.image,
      oidc_sub: auth.uid,
      oidc_issuer: auth.extra.raw_info.userinfo["iss"] || "unknown",
      oidc_claims: auth.extra.raw_info.userinfo || %{}
    }

    case Accounts.find_or_create_from_oidc(user_attrs) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> json(%{ok: true, user_id: user.id})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "failed to authenticate"})
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "authentication failed"})
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> json(%{ok: true})
  end
end
