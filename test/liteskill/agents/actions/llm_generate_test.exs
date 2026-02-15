defmodule Liteskill.Agents.Actions.LlmGenerateTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Agents.Actions.LlmGenerate
  alias Liteskill.LlmProviders
  alias Liteskill.LlmModels

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "llmgen-#{System.unique_integer([:positive])}@example.com",
        name: "LLM Gen Owner",
        oidc_sub: "llmgen-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, provider} =
      LlmProviders.create_provider(%{
        name: "Test Provider #{System.unique_integer([:positive])}",
        provider_type: "anthropic",
        provider_config: %{},
        user_id: owner.id
      })

    {:ok, model} =
      LlmModels.create_model(%{
        name: "Test Model #{System.unique_integer([:positive])}",
        model_id: "claude-3-5-sonnet-20241022",
        provider_id: provider.id,
        user_id: owner.id
      })

    on_exit(fn ->
      Application.delete_env(:liteskill, :test_req_opts)
      Application.delete_env(:req_llm, :anthropic_api_key)
    end)

    %{owner: owner, model: model}
  end

  defp stub_llm_response(text) do
    Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      response = %{
        "id" => "msg_test_#{System.unique_integer([:positive])}",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "model" => "claude-3-5-sonnet-20241022",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    Application.put_env(:liteskill, :test_req_opts,
      req_http_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")
  end

  defp make_context(state) do
    %{state: state}
  end

  describe "run/2 — no model" do
    test "returns error when no LLM model configured" do
      context =
        make_context(%{
          agent_name: "TestAgent",
          llm_model: nil,
          prompt: "hello"
        })

      assert {:error, msg} = LlmGenerate.run(%{}, context)
      assert msg =~ "No LLM model configured"
      assert msg =~ "TestAgent"
    end
  end

  describe "run/2 — successful generation" do
    test "generates text with basic prompt", %{model: model} do
      stub_llm_response("The answer is 42.")

      context =
        make_context(%{
          agent_name: "TestAgent",
          system_prompt: "You are helpful",
          backstory: "",
          opinions: %{},
          role: "analyst",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "What is the meaning of life?",
          prior_context: ""
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "The answer is 42."
      assert result.analysis =~ "TestAgent"
      assert result.analysis =~ "analyst"
      assert result.analysis =~ "direct"
      assert is_list(result.messages)
    end

    test "includes backstory and opinions in system prompt", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Verify system prompt contains backstory and opinions
        system = decoded["system"]

        assert is_binary(system) or is_list(system)

        system_text =
          if is_list(system) do
            Enum.map_join(system, " ", fn
              %{"text" => t} -> t
              s when is_binary(s) -> s
            end)
          else
            system
          end

        assert system_text =~ "Historical context"
        assert system_text =~ "key1"

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "Expert",
          system_prompt: "Be thorough",
          backstory: "Historical context",
          opinions: %{"key1" => "value1"},
          role: "researcher",
          strategy: "chain_of_thought",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Research this",
          prior_context: ""
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end

    test "includes prior context in user message", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Check that the user message includes prior context
        messages = decoded["messages"] || []
        user_msg = Enum.find(messages, &(&1["role"] == "user"))

        if user_msg do
          content = user_msg["content"]

          text =
            cond do
              is_binary(content) -> content
              is_list(content) -> Enum.map_join(content, " ", &(&1["text"] || ""))
              true -> ""
            end

          assert text =~ "Previous pipeline stage outputs"
          assert text =~ "Prior agent said something"
        end

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "Agent2",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Do the thing",
          prior_context: "Prior agent said something"
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end
  end

  describe "run/2 — LLM error" do
    test "returns error when LLM call fails", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "internal error"}))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "FailAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "fail",
          prior_context: ""
        })

      assert {:error, msg} = LlmGenerate.run(%{}, context)
      assert msg =~ "LLM call failed"
      assert msg =~ "FailAgent"
    end
  end

  describe "run/2 — tool-calling loop" do
    test "executes tool calls and loops back to LLM", %{model: model} do
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        call_num = Agent.get_and_update(call_counter, fn n -> {n, n + 1} end)

        response =
          if call_num == 0 do
            # First call: return a tool_use response
            %{
              "id" => "msg_tool",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me search."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_123",
                  "name" => "fake_search",
                  "input" => %{"query" => "test"}
                }
              ],
              "model" => "claude-3-5-sonnet-20241022",
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 15}
            }
          else
            # Second call: return final text response
            %{
              "id" => "msg_final",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Found the answer: 42"}],
              "model" => "claude-3-5-sonnet-20241022",
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      defmodule FakeSearch do
        def call_tool("fake_search", %{"query" => "test"}, _context) do
          {:ok, %{"content" => [%{"text" => "search result: 42"}]}}
        end
      end

      tool_spec = %{
        "toolSpec" => %{
          "name" => "fake_search",
          "description" => "Search for things",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }

      context =
        make_context(%{
          agent_name: "ToolAgent",
          system_prompt: "You can use tools",
          backstory: "",
          opinions: %{},
          role: "researcher",
          strategy: "react",
          llm_model: LlmModels.get_model!(model.id),
          tools: [tool_spec],
          tool_servers: %{"fake_search" => %{builtin: FakeSearch}},
          user_id: nil,
          prompt: "Find the answer",
          prior_context: ""
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "Found the answer: 42"
      assert Agent.get(call_counter, & &1) == 2

      Agent.stop(call_counter)
    end

    test "returns error when max tool rounds exceeded", %{model: model} do
      # Always return tool_use to trigger max rounds
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        response = %{
          "id" => "msg_loop",
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_#{System.unique_integer([:positive])}",
              "name" => "loop_tool",
              "input" => %{}
            }
          ],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "tool_use",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      defmodule LoopTool do
        def call_tool("loop_tool", _input, _context) do
          {:ok, %{"content" => [%{"text" => "result"}]}}
        end
      end

      tool_spec = %{
        "toolSpec" => %{
          "name" => "loop_tool",
          "description" => "A tool",
          "inputSchema" => %{"json" => %{}}
        }
      }

      context =
        make_context(%{
          agent_name: "LoopAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [tool_spec],
          tool_servers: %{"loop_tool" => %{builtin: LoopTool}},
          user_id: nil,
          prompt: "loop forever",
          prior_context: ""
        })

      assert {:error, msg} = LlmGenerate.run(%{max_tool_rounds: 1}, context)
      assert msg =~ "max_tool_rounds_exceeded"
    end
  end

  describe "run/2 — strategy hints" do
    test "includes correct strategy hint for each strategy", %{model: model} do
      for {strategy, expected_fragment} <- [
            {"react", "Reason-Act"},
            {"chain_of_thought", "chain-of-thought"},
            {"tree_of_thoughts", "multiple approaches"},
            {"direct", "direct, focused"},
            {"custom_strat", "custom_strat approach"}
          ] do
        stub_llm_response("ok")

        context =
          make_context(%{
            agent_name: "StratAgent",
            system_prompt: "",
            backstory: "",
            opinions: %{},
            role: "worker",
            strategy: strategy,
            llm_model: LlmModels.get_model!(model.id),
            tools: [],
            tool_servers: %{},
            user_id: nil,
            prompt: "test",
            prior_context: ""
          })

        assert {:ok, result} = LlmGenerate.run(%{}, context)
        # The strategy is reflected in the analysis header
        assert result.analysis =~ strategy
        # The system prompt should contain the strategy hint (checked via messages)
        system_msg = Enum.find(result.messages, &(&1["role"] == "system"))
        assert system_msg["content"] =~ expected_fragment
      end
    end
  end
end
