defmodule Liteskill.RagTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag
  alias Liteskill.Rag.{Collection, Source, Document, Chunk, CohereClient}

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "rag-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "rag-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  defp create_collection(user_id, attrs \\ %{}) do
    default = %{name: "Test Collection"}
    Rag.create_collection(Map.merge(default, attrs), user_id)
  end

  defp create_source(collection_id, user_id, attrs \\ %{}) do
    default = %{name: "Test Source"}
    Rag.create_source(collection_id, Map.merge(default, attrs), user_id)
  end

  defp create_document(source_id, user_id, attrs \\ %{}) do
    default = %{title: "Test Document"}
    Rag.create_document(source_id, Map.merge(default, attrs), user_id)
  end

  defp stub_embed(embeddings) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  defp stub_rerank(results) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => results}))
    end)
  end

  # --- Collections ---

  describe "create_collection/2" do
    test "creates collection with valid attrs", %{owner: owner} do
      assert {:ok, %Collection{} = coll} = create_collection(owner.id)
      assert coll.name == "Test Collection"
      assert coll.user_id == owner.id
      assert coll.embedding_dimensions == 1024
    end

    test "creates collection with custom dimensions", %{owner: owner} do
      assert {:ok, coll} = create_collection(owner.id, %{embedding_dimensions: 512})
      assert coll.embedding_dimensions == 512
    end

    test "fails with invalid dimensions", %{owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               create_collection(owner.id, %{embedding_dimensions: 999})
    end

    test "fails without name", %{owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               Rag.create_collection(%{}, owner.id)
    end
  end

  describe "list_collections/1" do
    test "lists own collections", %{owner: owner} do
      {:ok, _} = create_collection(owner.id, %{name: "A"})
      {:ok, _} = create_collection(owner.id, %{name: "B"})

      collections = Rag.list_collections(owner.id)
      assert length(collections) == 2
      assert Enum.map(collections, & &1.name) == ["A", "B"]
    end

    test "excludes other users' collections", %{owner: owner, other: other} do
      {:ok, _} = create_collection(owner.id)
      {:ok, _} = create_collection(other.id)

      assert length(Rag.list_collections(owner.id)) == 1
    end
  end

  describe "get_collection/2" do
    test "returns own collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, found} = Rag.get_collection(coll.id, owner.id)
      assert found.id == coll.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.get_collection(coll.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_collection(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_collection/3" do
    test "owner can update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, updated} = Rag.update_collection(coll.id, %{name: "Updated"}, owner.id)
      assert updated.name == "Updated"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.update_collection(coll.id, %{name: "Hacked"}, other.id)
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, %Ecto.Changeset{}} =
               Rag.update_collection(coll.id, %{embedding_dimensions: 999}, owner.id)
    end
  end

  describe "delete_collection/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, _} = Rag.delete_collection(coll.id, owner.id)
      assert Rag.list_collections(owner.id) == []
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.delete_collection(coll.id, other.id)
    end
  end

  # --- Sources ---

  describe "create_source/3" do
    test "creates source with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, %Source{} = source} = create_source(coll.id, owner.id)
      assert source.name == "Test Source"
      assert source.source_type == "manual"
      assert source.collection_id == coll.id
    end

    test "creates source with custom type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:ok, source} =
               create_source(coll.id, owner.id, %{source_type: "upload"})

      assert source.source_type == "upload"
    end

    test "fails with invalid source_type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, %Ecto.Changeset{}} =
               create_source(coll.id, owner.id, %{source_type: "invalid"})
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = create_source(coll.id, other.id)
    end
  end

  describe "list_sources/2" do
    test "lists sources in collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, _} = create_source(coll.id, owner.id, %{name: "A"})
      {:ok, _} = create_source(coll.id, owner.id, %{name: "B"})

      assert {:ok, sources} = Rag.list_sources(coll.id, owner.id)
      assert length(sources) == 2
      assert Enum.map(sources, & &1.name) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.list_sources(coll.id, other.id)
    end
  end

  describe "get_source/2" do
    test "returns own source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, found} = Rag.get_source(source.id, owner.id)
      assert found.id == source.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.get_source(source.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_source(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_source/3" do
    test "owner can update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, updated} = Rag.update_source(source.id, %{name: "Updated"}, owner.id)
      assert updated.name == "Updated"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.update_source(source.id, %{name: "X"}, other.id)
    end
  end

  describe "delete_source/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, _} = Rag.delete_source(source.id, owner.id)
      assert {:ok, []} = Rag.list_sources(coll.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.delete_source(source.id, other.id)
    end
  end

  # --- Documents ---

  describe "create_document/3" do
    test "creates document with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, %Document{} = doc} = create_document(source.id, owner.id)
      assert doc.title == "Test Document"
      assert doc.status == "pending"
      assert doc.chunk_count == 0
    end

    test "creates document with content and metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      assert {:ok, doc} =
               create_document(source.id, owner.id, %{
                 content: "full text here",
                 metadata: %{"key" => "value"}
               })

      assert doc.content == "full text here"
      assert doc.metadata == %{"key" => "value"}
    end

    test "fails if source belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = create_document(source.id, other.id)
    end
  end

  describe "list_documents/2" do
    test "lists documents in source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, _} = create_document(source.id, owner.id, %{title: "A"})
      {:ok, _} = create_document(source.id, owner.id, %{title: "B"})

      assert {:ok, docs} = Rag.list_documents(source.id, owner.id)
      assert length(docs) == 2
      assert Enum.map(docs, & &1.title) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.list_documents(source.id, other.id)
    end
  end

  describe "get_document/2" do
    test "returns own document", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, found} = Rag.get_document(doc.id, owner.id)
      assert found.id == doc.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.get_document(doc.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_document(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "delete_document/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, _} = Rag.delete_document(doc.id, owner.id)
      assert {:ok, []} = Rag.list_documents(source.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.delete_document(doc.id, other.id)
    end
  end

  # --- Chunk Changeset ---

  describe "Chunk.changeset/2" do
    test "validates required fields" do
      changeset = Chunk.changeset(%Chunk{}, %{})
      refute changeset.valid?
      assert errors_on(changeset)[:content]
      assert errors_on(changeset)[:position]
      assert errors_on(changeset)[:document_id]
    end

    test "accepts valid attrs" do
      changeset =
        Chunk.changeset(%Chunk{}, %{
          content: "test",
          position: 0,
          document_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end
  end

  # --- Embed Chunks ---

  describe "embed_chunks/4" do
    test "embeds chunks and updates document status", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      emb1 = List.duplicate(0.1, 1024)
      emb2 = List.duplicate(0.2, 1024)
      stub_embed([emb1, emb2])

      chunks = [
        %{content: "chunk one", position: 0, metadata: %{"page" => 1}, token_count: 10},
        %{content: "chunk two", position: 1, metadata: %{"page" => 2}, token_count: 12}
      ]

      assert {:ok, updated_doc} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert updated_doc.status == "embedded"
      assert updated_doc.chunk_count == 2

      # Verify chunks were inserted
      db_chunks =
        Chunk
        |> where([c], c.document_id == ^doc.id)
        |> order_by([c], asc: c.position)
        |> Repo.all()

      assert length(db_chunks) == 2
      assert Enum.at(db_chunks, 0).content == "chunk one"
      assert Enum.at(db_chunks, 0).position == 0
      assert Enum.at(db_chunks, 0).token_count == 10
      assert Enum.at(db_chunks, 0).embedding != nil
      assert Enum.at(db_chunks, 1).content == "chunk two"
    end

    test "sets document status to error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "server error"}))
      end)

      chunks = [%{content: "chunk", position: 0}]

      assert {:error, %{status: 500}} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Document status should be "error"
      {:ok, reloaded} = Rag.get_document(doc.id, owner.id)
      assert reloaded.status == "error"
    end

    test "fails if document belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      assert {:error, :not_found} =
               Rag.embed_chunks(doc.id, [], other.id, plug: {Req.Test, CohereClient})
    end
  end

  # --- Search ---

  describe "search/4" do
    test "returns search results ordered by distance", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      # First, embed some chunks
      embedding1 = List.duplicate(0.1, 1024)
      embedding2 = List.duplicate(0.9, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        response =
          case Agent.get_and_update(agent, fn state ->
                 case state do
                   :embed -> {:embed, :search}
                   :search -> {:search, :search}
                 end
               end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding1, embedding2]}}

            :search ->
              query_type = decoded["input_type"]
              assert query_type == "search_query"
              %{"embeddings" => %{"float" => [embedding1]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "close chunk", position: 0, token_count: 5},
        %{content: "far chunk", position: 1, token_count: 5}
      ]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search(coll.id, "test query", owner.id, plug: {Req.Test, CohereClient})

      assert length(results) == 2
      assert hd(results).chunk.content == "close chunk"
      assert is_float(hd(results).distance)
    end

    test "respects limit option", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn s -> {s, :search} end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding, embedding, embedding]}}

            :search ->
              %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "a", position: 0},
        %{content: "b", position: 1},
        %{content: "c", position: 2}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search(coll.id, "query", owner.id,
                 limit: 1,
                 plug: {Req.Test, CohereClient}
               )

      assert length(results) == 1
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.search(coll.id, "q", other.id)
    end

    test "returns error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:error, %{status: 500}} =
               Rag.search(coll.id, "query", owner.id, plug: {Req.Test, CohereClient})
    end
  end

  # --- Rerank ---

  describe "rerank/3" do
    test "reranks chunks by relevance score" do
      chunks = [
        %{chunk: %Chunk{content: "doc a"}, distance: 0.1},
        %{chunk: %Chunk{content: "doc b"}, distance: 0.2},
        %{chunk: %Chunk{content: "doc c"}, distance: 0.3}
      ]

      stub_rerank([
        %{"index" => 2, "relevance_score" => 0.95},
        %{"index" => 0, "relevance_score" => 0.8}
      ])

      assert {:ok, ranked} =
               Rag.rerank("query", chunks, top_n: 2, plug: {Req.Test, CohereClient})

      assert length(ranked) == 2
      assert hd(ranked).chunk.content == "doc c"
      assert hd(ranked).relevance_score == 0.95
    end

    test "returns error on rerank failure" do
      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:error, _} =
               Rag.rerank("query", [%{chunk: %Chunk{content: "x"}, distance: 0.1}],
                 plug: {Req.Test, CohereClient}
               )
    end
  end

  # --- Search and Rerank ---

  describe "search_and_rerank/4" do
    test "pipelines search into rerank", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        response =
          cond do
            # First call: embed chunks
            call_num == 0 ->
              %{"embeddings" => %{"float" => [embedding, embedding]}}

            # Second call: search query embed
            Map.has_key?(decoded, "input_type") ->
              %{"embeddings" => %{"float" => [embedding]}}

            # Third call: rerank
            Map.has_key?(decoded, "query") ->
              %{
                "results" => [
                  %{"index" => 1, "relevance_score" => 0.9},
                  %{"index" => 0, "relevance_score" => 0.7}
                ]
              }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "first", position: 0},
        %{content: "second", position: 1}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, ranked} =
               Rag.search_and_rerank(coll.id, "query", owner.id,
                 search_limit: 50,
                 top_n: 2,
                 plug: {Req.Test, CohereClient}
               )

      assert length(ranked) == 2
      assert hd(ranked).relevance_score == 0.9
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, :not_found} =
               Rag.search_and_rerank(coll.id, "q", other.id, plug: {Req.Test, CohereClient})
    end
  end
end
