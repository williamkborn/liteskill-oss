defmodule Liteskill.Rag.CohereClientTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rag.CohereClient

  setup do
    original = Application.get_env(:liteskill, Liteskill.LLM, [])

    merged =
      Keyword.merge(original,
        bedrock_bearer_token: "test-token",
        bedrock_region: "us-east-1"
      )

    Application.put_env(:liteskill, Liteskill.LLM, merged)

    on_exit(fn ->
      Application.put_env(:liteskill, Liteskill.LLM, original)
    end)

    :ok
  end

  describe "embed/2" do
    test "returns embeddings on success" do
      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["texts"] == ["hello world"]
        assert decoded["input_type"] == "search_document"
        assert decoded["embedding_types"] == ["float"]
        assert decoded["output_dimension"] == 1024
        assert decoded["truncate"] == "RIGHT"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => %{"float" => [[0.1, 0.2, 0.3]]}
          })
        )
      end)

      assert {:ok, [[0.1, 0.2, 0.3]]} =
               CohereClient.embed(["hello world"],
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end

    test "passes custom dimensions" do
      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["output_dimension"] == 512

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => %{"float" => [[0.1, 0.2]]}
          })
        )
      end)

      assert {:ok, [[0.1, 0.2]]} =
               CohereClient.embed(["test"],
                 input_type: "search_query",
                 dimensions: 512,
                 plug: {Req.Test, CohereClient}
               )
    end

    test "returns error on non-200 response" do
      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"message" => "bad request"}))
      end)

      assert {:error, %{status: 400, body: %{"message" => "bad request"}}} =
               CohereClient.embed(["test"],
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end

    test "sends correct URL path" do
      Req.Test.stub(CohereClient, fn conn ->
        assert conn.request_path == "/model/cohere.embed-v4/invoke"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => %{"float" => [[0.1]]}
          })
        )
      end)

      CohereClient.embed(["test"],
        input_type: "search_document",
        plug: {Req.Test, CohereClient}
      )
    end

    test "sends authorization header" do
      Req.Test.stub(CohereClient, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => %{"float" => [[0.1]]}
          })
        )
      end)

      CohereClient.embed(["test"],
        input_type: "search_document",
        plug: {Req.Test, CohereClient}
      )
    end

    test "embeds multiple texts" do
      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert length(decoded["texts"]) == 3

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => %{"float" => [[0.1], [0.2], [0.3]]}
          })
        )
      end)

      assert {:ok, [[0.1], [0.2], [0.3]]} =
               CohereClient.embed(["a", "b", "c"],
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end
  end

  describe "rerank/3" do
    test "returns ranked results on success" do
      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["query"] == "test query"
        assert decoded["documents"] == ["doc1", "doc2"]
        assert decoded["top_n"] == 5
        assert decoded["max_tokens_per_doc"] == 4096
        assert decoded["api_version"] == 2

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{"index" => 1, "relevance_score" => 0.9},
              %{"index" => 0, "relevance_score" => 0.5}
            ]
          })
        )
      end)

      assert {:ok,
              [
                %{"index" => 1, "relevance_score" => 0.9},
                %{"index" => 0, "relevance_score" => 0.5}
              ]} =
               CohereClient.rerank("test query", ["doc1", "doc2"], plug: {Req.Test, CohereClient})
    end

    test "passes custom top_n and max_tokens_per_doc" do
      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["top_n"] == 3
        assert decoded["max_tokens_per_doc"] == 2048

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "results" => [%{"index" => 0, "relevance_score" => 0.8}]
          })
        )
      end)

      assert {:ok, [%{"index" => 0, "relevance_score" => 0.8}]} =
               CohereClient.rerank("query", ["doc"],
                 top_n: 3,
                 max_tokens_per_doc: 2048,
                 plug: {Req.Test, CohereClient}
               )
    end

    test "returns error on non-200 response" do
      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "rate limited"}))
      end)

      assert {:error, %{status: 429, body: %{"message" => "rate limited"}}} =
               CohereClient.rerank("query", ["doc"], plug: {Req.Test, CohereClient})
    end

    test "sends correct URL path for rerank model" do
      Req.Test.stub(CohereClient, fn conn ->
        assert conn.request_path == "/model/cohere.rerank-v3-5:0/invoke"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "results" => []
          })
        )
      end)

      CohereClient.rerank("query", ["doc"], plug: {Req.Test, CohereClient})
    end
  end
end
