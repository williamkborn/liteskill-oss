defmodule Liteskill.LLMTest do
  use ExUnit.Case, async: true

  alias Liteskill.LLM
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider

  setup do
    Application.put_env(:liteskill, Liteskill.LLM, bedrock_region: "us-east-1")

    :ok
  end

  defp fake_response(text) do
    %ReqLLM.Response{
      id: "resp-1",
      model: "test",
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 5},
      context: ReqLLM.Context.new([])
    }
  end

  defp fake_generate(text) do
    fn _model, _context, _opts ->
      {:ok, fake_response(text)}
    end
  end

  describe "complete/2" do
    test "returns formatted response from ReqLLM" do
      messages = [%{role: :user, content: "Hello"}]

      assert {:ok,
              %{
                "output" => %{
                  "message" => %{"role" => "assistant", "content" => [%{"text" => "Hi there"}]}
                }
              }} =
               LLM.complete(messages,
                 model_id: "test-model",
                 generate_fn: fake_generate("Hi there")
               )
    end

    test "allows overriding model_id" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn model, _context, _opts ->
        assert model == %{id: "custom-model", provider: :amazon_bedrock}
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} = LLM.complete(messages, model_id: "custom-model", generate_fn: generate_fn)
    end

    test "passes system prompt option" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn _model, _context, opts ->
        assert Keyword.get(opts, :system_prompt) == "Be brief"
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 system: "Be brief",
                 generate_fn: generate_fn
               )
    end

    test "passes temperature and max_tokens" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn _model, _context, opts ->
        assert Keyword.get(opts, :temperature) == 0.5
        assert Keyword.get(opts, :max_tokens) == 100
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 temperature: 0.5,
                 max_tokens: 100,
                 generate_fn: generate_fn
               )
    end

    test "returns error on failure" do
      messages = [%{role: :user, content: "Hello"}]

      generate_fn = fn _model, _context, _opts ->
        {:error, %{status: 500, body: "Internal error"}}
      end

      assert {:error, %{status: 500}} =
               LLM.complete(messages, model_id: "test-model", generate_fn: generate_fn)
    end
  end

  test "passes explicit provider_options through to generate_fn" do
    messages = [%{role: :user, content: "Hello"}]

    generate_fn = fn _model, _context, opts ->
      provider_opts = Keyword.get(opts, :provider_options, [])
      assert Keyword.get(provider_opts, :api_key) == "test-token"
      assert Keyword.get(provider_opts, :region) == "us-east-1"
      {:ok, fake_response("ok")}
    end

    assert {:ok, _} =
             LLM.complete(messages,
               model_id: "test-model",
               provider_options: [api_key: "test-token", region: "us-east-1"],
               generate_fn: generate_fn
             )
  end

  describe "complete/2 with llm_model" do
    test "uses llm_model for provider options when provided" do
      llm_model = %LlmModel{
        model_id: "claude-3-5-sonnet",
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      generate_fn = fn model, _context, opts ->
        assert model == %{id: "claude-3-5-sonnet", provider: :anthropic}
        assert Keyword.get(opts, :provider_options) == [api_key: "test-key"]
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete([%{role: :user, content: "Hi"}],
                 llm_model: llm_model,
                 generate_fn: generate_fn
               )
    end

    test "llm_model with amazon_bedrock includes region and use_converse" do
      llm_model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: %LlmProvider{
          provider_type: "amazon_bedrock",
          api_key: "bedrock-token",
          provider_config: %{"region" => "us-west-2"}
        }
      }

      generate_fn = fn model, _context, opts ->
        assert model == %{
                 id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
                 provider: :amazon_bedrock
               }

        provider_opts = Keyword.get(opts, :provider_options)
        assert Keyword.get(provider_opts, :region) == "us-west-2"
        assert Keyword.get(provider_opts, :use_converse) == true
        assert Keyword.get(provider_opts, :api_key) == "bedrock-token"
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete([%{role: :user, content: "Hi"}],
                 llm_model: llm_model,
                 generate_fn: generate_fn
               )
    end
  end

  test "raises when no model specified" do
    messages = [%{role: :user, content: "Hello"}]

    assert_raise RuntimeError, ~r/No model specified/, fn ->
      LLM.complete(messages, generate_fn: fn _, _, _ -> {:ok, fake_response("ok")} end)
    end
  end
end
