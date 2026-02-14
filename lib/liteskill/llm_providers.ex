defmodule Liteskill.LlmProviders do
  @moduledoc """
  Context for managing LLM provider configurations.

  Each provider represents a connection endpoint with credentials.
  Admin-only CRUD; access via instance_wide flag or entity ACLs.
  """

  alias Liteskill.Authorization
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  import Ecto.Query

  # --- Admin CRUD ---

  def create_provider(attrs) do
    Repo.transaction(fn ->
      case %LlmProvider{}
           |> LlmProvider.changeset(attrs)
           |> Repo.insert() do
        {:ok, provider} ->
          {:ok, _} = Authorization.create_owner_acl("llm_provider", provider.id, provider.user_id)
          provider

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_provider(id, user_id, attrs) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      provider ->
        with {:ok, provider} <- authorize_owner(provider, user_id) do
          provider
          |> LlmProvider.changeset(attrs)
          |> Repo.update()
        end
    end
  end

  def delete_provider(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      provider ->
        with {:ok, provider} <- authorize_owner(provider, user_id) do
          Repo.delete(provider)
        end
    end
  end

  # --- User-facing queries ---

  def list_providers(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("llm_provider", user_id)

    LlmProvider
    |> where(
      [p],
      p.user_id == ^user_id or p.instance_wide == true or p.id in subquery(accessible_ids)
    )
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def get_provider(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      %LlmProvider{user_id: ^user_id} = provider ->
        {:ok, provider}

      %LlmProvider{instance_wide: true} = provider ->
        {:ok, provider}

      %LlmProvider{} = provider ->
        if Authorization.has_access?("llm_provider", provider.id, user_id) do
          {:ok, provider}
        else
          {:error, :not_found}
        end
    end
  end

  def get_provider!(id) do
    Repo.get!(LlmProvider, id)
  end

  # --- Private ---

  defp authorize_owner(%LlmProvider{user_id: user_id} = provider, user_id), do: {:ok, provider}
  defp authorize_owner(_, _), do: {:error, :forbidden}
end
