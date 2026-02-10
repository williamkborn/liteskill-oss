defmodule Liteskill.Rag do
  @moduledoc """
  The RAG context. Manages collections, sources, documents, chunks,
  embedding generation, and semantic search.
  """

  alias Liteskill.Rag.{Collection, Source, Document, Chunk, CohereClient, IngestWorker}
  alias Liteskill.Repo

  import Ecto.Query

  # --- Collections ---

  def create_collection(attrs, user_id) do
    %Collection{}
    |> Collection.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  def list_collections(user_id) do
    Collection
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def get_collection(id, user_id) do
    case Repo.get(Collection, id) do
      nil -> {:error, :not_found}
      %Collection{user_id: ^user_id} = collection -> {:ok, collection}
      _ -> {:error, :not_found}
    end
  end

  def update_collection(id, attrs, user_id) do
    with {:ok, collection} <- get_collection(id, user_id) do
      collection
      |> Collection.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_collection(id, user_id) do
    with {:ok, collection} <- get_collection(id, user_id) do
      Repo.delete(collection)
    end
  end

  # --- Sources ---

  def create_source(collection_id, attrs, user_id) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      %Source{}
      |> Source.changeset(
        attrs
        |> Map.put(:collection_id, collection_id)
        |> Map.put(:user_id, user_id)
      )
      |> Repo.insert()
    end
  end

  def list_sources(collection_id, user_id) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      sources =
        Source
        |> where([s], s.collection_id == ^collection_id)
        |> order_by([s], asc: s.name)
        |> Repo.all()

      {:ok, sources}
    end
  end

  def get_source(id, user_id) do
    case Repo.get(Source, id) do
      nil -> {:error, :not_found}
      %Source{user_id: ^user_id} = source -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end

  def update_source(id, attrs, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      source
      |> Source.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_source(id, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      Repo.delete(source)
    end
  end

  # --- Documents ---

  def create_document(source_id, attrs, user_id) do
    with {:ok, _source} <- get_source(source_id, user_id) do
      %Document{}
      |> Document.changeset(
        attrs
        |> Map.put(:source_id, source_id)
        |> Map.put(:user_id, user_id)
      )
      |> Repo.insert()
    end
  end

  def list_documents(source_id, user_id) do
    with {:ok, _source} <- get_source(source_id, user_id) do
      documents =
        Document
        |> where([d], d.source_id == ^source_id)
        |> order_by([d], asc: d.title)
        |> Repo.all()

      {:ok, documents}
    end
  end

  def get_document(id, user_id) do
    case Repo.get(Document, id) do
      nil -> {:error, :not_found}
      %Document{user_id: ^user_id} = document -> {:ok, document}
      _ -> {:error, :not_found}
    end
  end

  def delete_document(id, user_id) do
    with {:ok, document} <- get_document(id, user_id) do
      Repo.delete(document)
    end
  end

  # --- Embedding ---

  def embed_chunks(document_id, chunks, user_id, opts \\ []) do
    with {:ok, document} <- get_document(document_id, user_id),
         {:ok, source} <- get_source(document.source_id, user_id),
         {:ok, collection} <- get_collection(source.collection_id, user_id) do
      {plug_opts, _rest} = Keyword.split(opts, [:plug])
      dimensions = Keyword.get(opts, :dimensions, collection.embedding_dimensions)
      texts = Enum.map(chunks, & &1.content)

      case CohereClient.embed(
             texts,
             [{:input_type, "search_document"}, {:dimensions, dimensions}] ++ plug_opts
           ) do
        {:ok, embeddings} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          chunk_rows =
            chunks
            |> Enum.zip(embeddings)
            |> Enum.map(fn {chunk, embedding} ->
              %{
                id: Ecto.UUID.generate(),
                content: chunk.content,
                position: chunk.position,
                metadata: Map.get(chunk, :metadata, %{}),
                token_count: Map.get(chunk, :token_count),
                embedding: Pgvector.new(embedding),
                document_id: document_id,
                inserted_at: now,
                updated_at: now
              }
            end)

          Repo.transaction(fn ->
            Repo.insert_all(Chunk, chunk_rows)

            document
            |> Document.changeset(%{status: "embedded", chunk_count: length(chunks)})
            |> Repo.update!()
          end)

        {:error, reason} ->
          document
          |> Document.changeset(%{status: "error"})
          |> Repo.update()

          {:error, reason}
      end
    end
  end

  # --- Search ---

  def search(collection_id, query, user_id, opts \\ []) do
    with {:ok, collection} <- get_collection(collection_id, user_id) do
      {plug_opts, _rest} = Keyword.split(opts, [:plug])
      dimensions = Keyword.get(opts, :dimensions, collection.embedding_dimensions)
      limit = Keyword.get(opts, :limit, 20)

      case CohereClient.embed(
             [query],
             [{:input_type, "search_query"}, {:dimensions, dimensions}] ++ plug_opts
           ) do
        {:ok, [query_embedding]} ->
          results = vector_search(collection_id, query_embedding, limit)
          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def rerank(query, chunks, opts \\ []) do
    {plug_opts, rest} = Keyword.split(opts, [:plug])
    top_n = Keyword.get(rest, :top_n, 5)
    texts = Enum.map(chunks, fn %{chunk: c} -> c.content end)

    case CohereClient.rerank(query, texts, [{:top_n, top_n}] ++ plug_opts) do
      {:ok, results} ->
        ranked =
          Enum.map(results, fn %{"index" => idx, "relevance_score" => score} ->
            %{chunk: Enum.at(chunks, idx).chunk, relevance_score: score}
          end)

        {:ok, ranked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def search_and_rerank(collection_id, query, user_id, opts \\ []) do
    {plug_opts, rest} = Keyword.split(opts, [:plug])
    search_limit = Keyword.get(rest, :search_limit, 50)
    top_n = Keyword.get(rest, :top_n, 5)
    dimensions = Keyword.get(rest, :dimensions)

    search_opts = [{:limit, search_limit}] ++ plug_opts
    search_opts = if dimensions, do: [{:dimensions, dimensions} | search_opts], else: search_opts

    with {:ok, search_results} <- search(collection_id, query, user_id, search_opts) do
      rerank(query, search_results, [{:top_n, top_n}] ++ plug_opts)
    end
  end

  # --- Ingest ---

  def ingest_url(collection_id, url, user_id, opts \\ []) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      method = Keyword.get(opts, :method, "GET")
      headers = Keyword.get(opts, :headers, %{})
      plug = Keyword.get(opts, :plug, false)
      chunk_size = Keyword.get(opts, :chunk_size)
      overlap = Keyword.get(opts, :overlap)

      chunk_opts =
        %{}
        |> maybe_put_arg("chunk_size", chunk_size)
        |> maybe_put_arg("overlap", overlap)

      args = %{
        "url" => url,
        "collection_id" => collection_id,
        "user_id" => user_id,
        "method" => method,
        "headers" => headers,
        "chunk_opts" => chunk_opts,
        "plug" => plug
      }

      IngestWorker.new(args) |> Oban.insert()
    end
  end

  defp maybe_put_arg(map, _key, nil), do: map
  defp maybe_put_arg(map, key, value), do: Map.put(map, key, value)

  # --- Private ---

  defp vector_search(collection_id, query_embedding, limit) do
    query_vector = Pgvector.new(query_embedding)

    from(c in Chunk,
      join: d in Document,
      on: d.id == c.document_id,
      join: s in Source,
      on: s.id == d.source_id,
      where: s.collection_id == ^collection_id,
      where: not is_nil(c.embedding),
      order_by: fragment("embedding <=> ?", ^query_vector),
      limit: ^limit,
      select: %{chunk: c, distance: fragment("embedding <=> ?", ^query_vector)}
    )
    |> Repo.all()
  end
end
