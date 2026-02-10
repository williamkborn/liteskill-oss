defmodule Liteskill.McpServers do
  @moduledoc """
  The McpServers context. Manages MCP server registrations per user.
  """

  alias Liteskill.McpServers.McpServer
  alias Liteskill.Repo

  import Ecto.Query

  def list_servers(user_id) do
    db_servers =
      McpServer
      |> where([s], s.user_id == ^user_id or s.global == true)
      |> order_by([s], asc: s.name)
      |> Repo.all()

    Liteskill.BuiltinTools.virtual_servers() ++ db_servers
  end

  def get_server("builtin:" <> _ = id, _user_id) do
    case Enum.find(Liteskill.BuiltinTools.virtual_servers(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      server -> {:ok, server}
    end
  end

  def get_server(id, user_id) do
    case Repo.get(McpServer, id) do
      nil ->
        {:error, :not_found}

      %McpServer{user_id: ^user_id} = server ->
        {:ok, server}

      %McpServer{global: true} = server ->
        {:ok, server}

      _ ->
        {:error, :not_found}
    end
  end

  def create_server(attrs) do
    %McpServer{}
    |> McpServer.changeset(attrs)
    |> Repo.insert()
  end

  def update_server(server, user_id, attrs) do
    with {:ok, server} <- authorize_owner(server, user_id) do
      server
      |> McpServer.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_server(id, user_id) do
    case Repo.get(McpServer, id) do
      nil ->
        {:error, :not_found}

      server ->
        with {:ok, server} <- authorize_owner(server, user_id) do
          Repo.delete(server)
        end
    end
  end

  defp authorize_owner(%McpServer{user_id: user_id} = server, user_id), do: {:ok, server}
  defp authorize_owner(_, _), do: {:error, :forbidden}
end
