defmodule JaxrlDashboard.Repo.Migrations.AddProjectToRuns do
  use Ecto.Migration

  def change do
    # Every run so far is a jaxrl run. The default only backfills them; new
    # runs always say which project they're in.
    alter table(:runs) do
      add :project, :string, null: false, default: "jaxrl"
    end

    execute "ALTER TABLE runs ALTER COLUMN project DROP DEFAULT",
            "ALTER TABLE runs ALTER COLUMN project SET DEFAULT 'jaxrl'"

    create index(:runs, [:project])
  end
end
