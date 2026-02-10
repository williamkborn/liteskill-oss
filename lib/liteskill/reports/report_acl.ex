defmodule Liteskill.Reports.ReportAcl do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "report_acls" do
    field :role, :string, default: "member"

    belongs_to :report, Liteskill.Reports.Report
    belongs_to :user, Liteskill.Accounts.User
    belongs_to :group, Liteskill.Groups.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(acl, attrs) do
    acl
    |> cast(attrs, [:report_id, :user_id, :group_id, :role])
    |> validate_required([:report_id, :role])
    |> validate_inclusion(:role, ["owner", "member", "viewer"])
    |> validate_user_or_group()
    |> unique_constraint([:report_id, :user_id],
      name: :report_acls_report_id_user_id_index
    )
    |> unique_constraint([:report_id, :group_id],
      name: :report_acls_report_id_group_id_index
    )
    |> check_constraint(:user_id, name: :report_acl_user_or_group_required)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_user_or_group(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :group_id)

    cond do
      is_nil(user_id) and is_nil(group_id) ->
        add_error(changeset, :user_id, "either user_id or group_id must be set")

      not is_nil(user_id) and not is_nil(group_id) ->
        add_error(changeset, :user_id, "only one of user_id or group_id can be set")

      true ->
        changeset
    end
  end
end
