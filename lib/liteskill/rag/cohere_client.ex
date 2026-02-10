defmodule Liteskill.Rag.CohereClient do
  @moduledoc """
  Req-based HTTP client for Cohere models on AWS Bedrock.

  Supports embed-v4 and rerank-v3.5.
  """

  @embed_model "cohere.embed-v4"
  @rerank_model "cohere.rerank-v3-5:0"

  @doc """
  Embed a list of texts using Cohere embed-v4.

  Required opts:
    - `input_type` - "search_document" or "search_query"

  Optional opts:
    - `dimensions` - output dimension (default 1024)
    - `truncate` - truncation strategy (default "RIGHT")
    - `plug` - Req test plug
  """
  def embed(texts, opts \\ []) do
    {req_opts, body_opts} = Keyword.split(opts, [:plug])

    body = %{
      "texts" => texts,
      "input_type" => Keyword.fetch!(body_opts, :input_type),
      "embedding_types" => ["float"],
      "output_dimension" => Keyword.get(body_opts, :dimensions, 1024),
      "truncate" => Keyword.get(body_opts, :truncate, "RIGHT")
    }

    case Req.post(base_req(), [{:url, invoke_url(@embed_model)}, {:json, body}] ++ req_opts) do
      {:ok, %{status: 200, body: %{"embeddings" => %{"float" => embeddings}}}} ->
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rerank documents against a query using Cohere rerank-v3.5.

  Optional opts:
    - `top_n` - number of top results (default 5)
    - `max_tokens_per_doc` - max tokens per document (default 4096)
    - `plug` - Req test plug
  """
  def rerank(query, documents, opts \\ []) do
    {req_opts, body_opts} = Keyword.split(opts, [:plug])

    body = %{
      "query" => query,
      "documents" => documents,
      "top_n" => Keyword.get(body_opts, :top_n, 5),
      "max_tokens_per_doc" => Keyword.get(body_opts, :max_tokens_per_doc, 4096),
      "api_version" => 2
    }

    case Req.post(base_req(), [{:url, invoke_url(@rerank_model)}, {:json, body}] ++ req_opts) do
      {:ok, %{status: 200, body: %{"results" => results}}} ->
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_req do
    token = config(:bedrock_bearer_token)

    Req.new(
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ]
    )
  end

  defp invoke_url(model_id) do
    region = config(:bedrock_region)
    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model_id)}/invoke"
  end

  defp config(key) do
    Application.get_env(:liteskill, Liteskill.LLM, [])
    |> Keyword.get(key)
  end
end
