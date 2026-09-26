defmodule JaxrlDashboard.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :name, :string, null: false
      add :status, :string, null: false
      add :config, :map, null: false
      add :config_source, :string
      add :pid, :integer
      add :exit_code, :integer
      add :error, :text
      add :cancel_requested_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:runs, [:name])
    create index(:runs, [:status])
    create index(:runs, [:user_id])
  end
end
