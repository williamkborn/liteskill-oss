defmodule Liteskill.McpServers.McpServer do
  @moduledoc """
  Schema for MCP (Model Context Protocol) server registrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "mcp_servers" do
    field :name, :string
    field :url, :string
    field :api_key, Liteskill.Crypto.EncryptedField
    field :description, :string
    field :headers, :map, default: %{}
    field :status, :string, default: "active"
    field :global, :boolean, default: false

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(server, attrs) do
    server
    |> cast(attrs, [:name, :url, :api_key, :description, :headers, :status, :global, :user_id])
    |> validate_required([:name, :url, :user_id])
    |> validate_inclusion(:status, ["active", "inactive"])
    |> foreign_key_constraint(:user_id)
  end
end
