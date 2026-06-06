defmodule Tracy.MemoryTest do
  use Tracy.DataCase, async: true

  alias Tracy.Memory
  alias Tracy.Memory.{Episode, Fact, Procedure}

  describe "record_episode/2" do
    test "inserts an episode and computes an embedding by default" do
      assert {:ok, %Episode{} = ep} =
               Memory.record_episode(%{
                 source: "session",
                 body: "matt said hello to tracy"
               })

      assert ep.body =~ "matt"
      assert ep.source == "session"
      assert ep.occurred_at != nil
      assert ep.embedding != nil
      assert length(Pgvector.to_list(ep.embedding)) == 768
    end

    test "respects embed: false" do
      assert {:ok, %Episode{embedding: nil}} =
               Memory.record_episode(
                 %{source: "system", body: "no vector please"},
                 embed: false
               )
    end

    test "validates source is in the allowed set" do
      assert {:error, changeset} =
               Memory.record_episode(%{source: "made-up", body: "x"})

      assert %{source: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "record_fact/2 and current_facts/1" do
    test "records a current fact (valid_to == nil) with embedding" do
      assert {:ok, %Fact{} = fact} =
               Memory.record_fact(%{
                 statement: "Matt prefers Phoenix without umbrellas",
                 subject: "matt"
               })

      assert fact.valid_to == nil
      assert fact.embedding != nil
    end

    test "current_facts/1 returns only valid_to IS NULL rows" do
      {:ok, _current} = Memory.record_fact(%{statement: "current claim", subject: "tracy"})
      {:ok, expired} = Memory.record_fact(%{statement: "expired claim", subject: "tracy"})

      expired
      |> Ecto.Changeset.change(valid_to: DateTime.utc_now())
      |> Tracy.Repo.update!()

      statements =
        Memory.current_facts(subject: "tracy")
        |> Enum.map(& &1.statement)

      assert "current claim" in statements
      refute "expired claim" in statements
    end
  end

  describe "supersede_fact/3" do
    test "inserts the new fact and closes the old in a transaction" do
      {:ok, old} = Memory.record_fact(%{statement: "old view", subject: "tracy"})

      assert {:ok, %{new: %Fact{} = new_fact, old: %Fact{} = closed_old}} =
               Memory.supersede_fact(old, %{statement: "new view", subject: "tracy"})

      assert new_fact.valid_to == nil
      assert closed_old.valid_to != nil
      assert closed_old.superseded_by_id == new_fact.id
    end
  end

  describe "upsert_procedure/2" do
    test "creates a procedure on first call" do
      assert {:ok, %Procedure{} = p} =
               Memory.upsert_procedure(%{
                 name: "commit-style",
                 body: "imperative mood, soft 72-char wrap",
                 description: "how Matt writes commits"
               })

      assert p.version == 1
      assert p.is_current
      assert p.embedding != nil
    end

    test "is idempotent when body is unchanged" do
      attrs = %{name: "stay-the-same", body: "unchanged content"}
      assert {:ok, first} = Memory.upsert_procedure(attrs)
      assert {:ok, second} = Memory.upsert_procedure(attrs)
      assert first.id == second.id
      assert second.version == 1
    end

    test "bumps the version and marks old not-current on body change" do
      assert {:ok, v1} = Memory.upsert_procedure(%{name: "evolve", body: "first"})
      assert {:ok, v2} = Memory.upsert_procedure(%{name: "evolve", body: "second"})

      assert v2.version == 2
      assert v2.is_current
      refute v2.id == v1.id

      assert Tracy.Repo.get(Procedure, v1.id).is_current == false
    end
  end

  describe "search/2" do
    test "returns layer-keyed results scored by RRF" do
      {:ok, _ep} = Memory.record_episode(%{source: "session", body: "boardroom plan for monday"})
      {:ok, _f} = Memory.record_fact(%{statement: "Tracy is the boardroom", subject: "tracy"})

      {:ok, _proc} =
        Memory.upsert_procedure(%{name: "boardroom-rules", body: "speak briefly in the boardroom"})

      results = Memory.search("boardroom")
      assert Map.has_key?(results, :episodes)
      assert Map.has_key?(results, :facts)
      assert Map.has_key?(results, :procedures)

      Enum.each(results, fn {_layer, list} ->
        assert is_list(list)
        Enum.each(list, fn {row, score} ->
          assert is_struct(row)
          assert is_float(score)
          assert score > 0
        end)
      end)
    end

    test "limit is per-layer" do
      Enum.each(1..6, fn n ->
        Memory.record_episode(%{source: "session", body: "limit test #{n}"})
      end)

      %{episodes: episodes} = Memory.search("limit test", layers: [:episodes], limit: 3)
      assert length(episodes) <= 3
    end
  end
end
