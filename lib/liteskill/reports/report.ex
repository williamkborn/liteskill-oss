defmodule Liteskill.Reports.Report do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reports" do
    field :title, :string

    belongs_to :user, Liteskill.Accounts.User
    has_many :sections, Liteskill.Reports.ReportSection
    has_many :acls, Liteskill.Reports.ReportAcl

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:title, :user_id])
    |> validate_required([:title, :user_id])
    |> foreign_key_constraint(:user_id)
  end
end
