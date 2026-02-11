defmodule Liteskill.Accounts do
  @moduledoc """
  The Accounts context. Manages user records created from OIDC or password authentication.
  """

  alias Liteskill.Accounts.User
  alias Liteskill.Repo

  import Ecto.Query

  @doc """
  Ensures the root admin user exists. Called on application boot.
  Creates admin@liteskill.local if missing; forces role to "admin" if changed.
  """
  def ensure_admin_user do
    email = User.admin_email()

    case get_user_by_email(email) do
      nil ->
        %User{email: email, name: "Admin", role: "admin"}
        |> Repo.insert!()

      %User{role: "admin"} = user ->
        user

      user ->
        user
        |> User.role_changeset(%{role: "admin"})
        |> Repo.update!()
    end
  end

  @doc """
  Finds an existing user by OIDC subject+issuer or creates a new one.
  Idempotent -- safe to call on every login callback.
  """
  def find_or_create_from_oidc(attrs) do
    sub = Map.fetch!(attrs, :oidc_sub)
    issuer = Map.fetch!(attrs, :oidc_issuer)

    case Repo.one(from u in User, where: u.oidc_sub == ^sub and u.oidc_issuer == ^issuer) do
      nil ->
        %User{}
        |> User.changeset(Map.new(attrs))
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  @doc """
  Registers a new user with email and password.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by email and password.
  """
  def authenticate_by_email_password(email, password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(from u in User, where: u.email == ^email)
  end

  @doc """
  Gets a user by ID. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by ID. Returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Lists all users ordered by email.
  """
  def list_users do
    Repo.all(from u in User, order_by: u.email)
  end

  @doc """
  Updates a user's role. Prevents demoting the root admin.
  """
  def update_user_role(user_id, role) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      %User{email: email} when email == "admin@liteskill.local" and role != "admin" ->
        {:error, :cannot_demote_root_admin}

      user ->
        user
        |> User.role_changeset(%{role: role})
        |> Repo.update()
    end
  end

  @doc """
  Changes a user's password. Requires current password verification.
  """
  def change_password(user, current_password, new_password) do
    if User.valid_password?(user, current_password) do
      user
      |> User.password_changeset(%{password: new_password})
      |> Repo.update()
    else
      {:error, :invalid_current_password}
    end
  end

  @doc """
  Sets password for first-time admin setup. No current password required.
  """
  def setup_admin_password(user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Repo.update()
  end

  @doc """
  Updates user preferences by merging new keys into the existing map.
  """
  def update_preferences(user, new_prefs) do
    merged = Map.merge(user.preferences || %{}, new_prefs)

    user
    |> User.preferences_changeset(%{preferences: merged})
    |> Repo.update()
  end
end
