defmodule Tracy.Repo.Migrations.InstallExtensions do
  use Ecto.Migration

  # Runs before any other migration so subsequent schemas can use vector / age types.
  # Both extensions must be installed at the cluster level (system pgvector + apache-age packages).
  #
  # NOTE: AGE requires `LOAD 'age'` and `SET search_path = ag_catalog, "$user", public`
  # per session BEFORE issuing Cypher queries. We DO NOT set search_path here because
  # it persists across subsequent migrations and causes new tables to land in ag_catalog
  # instead of public. Apply those settings per-query in Tracy.Graph (or equivalent)
  # when actually executing Cypher.
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")
    execute("CREATE EXTENSION IF NOT EXISTS age")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS age")
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
