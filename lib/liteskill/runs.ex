defmodule Liteskill.Runs do
  @moduledoc """
  Context for managing runs — runtime task executions.

  Each run represents a single execution: it has a prompt, optional team,
  topology, and tracks its lifecycle from pending through completed/failed.
  """

  alias Liteskill.Runs.{Run, RunLog, RunTask}
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_run(attrs) do
    Repo.transaction(fn ->
      case %Run{}
           |> Run.changeset(attrs)
           |> Repo.insert() do
        {:ok, run} ->
          {:ok, _} =
            Authorization.create_owner_acl("run", run.id, run.user_id)

          Repo.preload(run, [:team_definition, :run_tasks, :run_logs])

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_run(id, user_id, attrs) do
    case Repo.get(Run, id) do
      nil ->
        {:error, :not_found}

      run ->
        with {:ok, run} <- authorize_owner(run, user_id) do
          run
          |> Run.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              {:ok, Repo.preload(updated, [:team_definition, :run_tasks, :run_logs])}

            error ->
              error
          end
        end
    end
  end

  def delete_run(id, user_id) do
    case Repo.get(Run, id) do
      nil ->
        {:error, :not_found}

      run ->
        with {:ok, run} <- authorize_owner(run, user_id) do
          Repo.delete(run)
        end
    end
  end

  # --- Queries ---

  def list_runs(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("run", user_id)

    Run
    |> where([r], r.user_id == ^user_id or r.id in subquery(accessible_ids))
    |> order_by([r], desc: r.inserted_at)
    |> preload([:team_definition, :run_tasks, :run_logs])
    |> Repo.all()
  end

  def get_run(id, user_id) do
    case Repo.get(Run, id)
         |> Repo.preload([:team_definition, :run_tasks, :run_logs]) do
      nil ->
        {:error, :not_found}

      %Run{user_id: ^user_id} = run ->
        {:ok, run}

      %Run{} = run ->
        if Authorization.has_access?("run", run.id, user_id) do
          {:ok, run}
        else
          {:error, :not_found}
        end
    end
  end

  def get_run!(id) do
    Repo.get!(Run, id) |> Repo.preload([:team_definition, :run_tasks, :run_logs])
  end

  # --- Run Tasks ---

  def add_task(run_id, attrs) do
    %RunTask{}
    |> RunTask.changeset(Map.put(attrs, :run_id, run_id))
    |> Repo.insert()
  end

  def update_task(task_id, attrs) do
    case Repo.get(RunTask, task_id) do
      nil -> {:error, :not_found}
      task -> task |> RunTask.changeset(attrs) |> Repo.update()
    end
  end

  # --- Run Logs ---

  def get_log(log_id, user_id) do
    case Repo.get(RunLog, log_id) |> Repo.preload(:run) do
      nil ->
        {:error, :not_found}

      %RunLog{run: %Run{user_id: ^user_id}} = log ->
        {:ok, log}

      %RunLog{run: run} = log ->
        if Authorization.has_access?("run", run.id, user_id) do
          {:ok, log}
        else
          {:error, :not_found}
        end
    end
  end

  def add_log(run_id, level, step, message, metadata \\ %{}) do
    %RunLog{}
    |> RunLog.changeset(%{
      run_id: run_id,
      level: level,
      step: step,
      message: message,
      metadata: metadata
    })
    |> Repo.insert()
  end

  # --- Private ---

  defp authorize_owner(%Run{user_id: user_id} = run, user_id), do: {:ok, run}
  defp authorize_owner(_, _), do: {:error, :forbidden}
end
