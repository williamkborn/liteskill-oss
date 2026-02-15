defmodule Liteskill.Agents.Actions.LlmGenerate do
  @moduledoc """
  Jido Action that calls the LLM via ReqLLM with a tool-calling loop.

  Reads configuration from agent state (system_prompt, backstory, opinions,
  role, strategy, llm_model, tools, tool_servers) and makes a non-streaming
  LLM call. If the LLM returns tool calls, executes them and loops.
  """

  use Jido.Action,
    name: "llm_generate",
    description: "Calls the LLM with prompt, system prompt, and tools",
    schema: [
      max_tool_rounds: [type: :integer, default: 10]
    ]

  alias Liteskill.LLM.ToolUtils

  require Logger

  @max_tool_rounds 10

  def run(params, context) do
    state = context.state

    unless state[:llm_model] do
      {:error, "No LLM model configured for agent '#{state[:agent_name]}'"}
    else
      system_prompt = build_system_prompt(state)
      user_message = build_user_message(state)
      llm_context = ReqLLM.Context.new([ReqLLM.Context.user(user_message)])
      max_rounds = params[:max_tool_rounds] || @max_tool_rounds

      case llm_call_loop(state[:llm_model], system_prompt, llm_context, state, max_rounds, 0) do
        {:ok, response_text, final_context} ->
          analysis = build_analysis_header(state)
          messages = serialize_context(system_prompt, final_context)
          {:ok, %{analysis: analysis, output: response_text, messages: messages}}

        {:error, reason} ->
          {:error, "LLM call failed for agent '#{state[:agent_name]}': #{inspect(reason)}"}
      end
    end
  end

  # -- System prompt construction --

  defp build_system_prompt(state) do
    parts = []

    parts =
      if state[:system_prompt] && state[:system_prompt] != "" do
        parts ++ [state[:system_prompt]]
      else
        parts
      end

    parts = parts ++ ["You are acting as a #{state[:role]} in a multi-agent pipeline."]

    parts =
      if state[:backstory] && state[:backstory] != "" do
        parts ++ ["Background: #{state[:backstory]}"]
      else
        parts
      end

    parts =
      if is_map(state[:opinions]) && map_size(state[:opinions]) > 0 do
        opinion_lines =
          Enum.map_join(state[:opinions], "\n", fn {k, v} -> "- #{k}: #{v}" end)

        parts ++ ["Your perspectives:\n#{opinion_lines}"]
      else
        parts
      end

    strategy_hint =
      case state[:strategy] do
        "react" ->
          "Use a Reason-Act approach: think step by step, observe, then act."

        "chain_of_thought" ->
          "Use chain-of-thought reasoning: work through the problem step by step."

        "tree_of_thoughts" ->
          "Explore multiple approaches before selecting the best one."

        "direct" ->
          "Provide a direct, focused response."

        other ->
          "Use the #{other} approach."
      end

    parts = parts ++ [strategy_hint]

    Enum.join(parts, "\n\n")
  end

  defp build_user_message(state) do
    base = state[:prompt] || ""

    if state[:prior_context] && state[:prior_context] != "" do
      "Previous pipeline stage outputs:\n#{state[:prior_context]}\n\nTask: #{base}"
    else
      base
    end
  end

  defp build_analysis_header(state) do
    "**Agent:** #{state[:agent_name]}\n" <>
      "**Role:** #{state[:role]}\n" <>
      "**Strategy:** #{state[:strategy]}\n"
  end

  # -- LLM call with tool loop --

  defp llm_call_loop(_model, _system, _context, state, max_rounds, round)
       when round >= max_rounds do
    Logger.warning("Max tool rounds (#{max_rounds}) exceeded for agent '#{state[:agent_name]}'")
    {:error, :max_tool_rounds_exceeded}
  end

  defp llm_call_loop(llm_model, system_prompt, llm_context, state, max_rounds, round)
       when round < max_rounds do
    {model_spec, req_opts} = Liteskill.LlmModels.build_provider_options(llm_model)
    req_opts = Keyword.merge(req_opts, Application.get_env(:liteskill, :test_req_opts, []))

    req_opts = Keyword.put(req_opts, :system_prompt, system_prompt)

    tools = state[:tools] || []

    req_opts =
      if tools != [] do
        reqllm_tools = Enum.map(tools, &ToolUtils.convert_tool/1)
        Keyword.put(req_opts, :tools, reqllm_tools)
      else
        req_opts
      end

    case ReqLLM.generate_text(model_spec, llm_context, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        raw_tool_calls = ReqLLM.Response.tool_calls(response) || []

        if raw_tool_calls == [] do
          {:ok, text, response.context}
        else
          tool_calls = Enum.map(raw_tool_calls, &normalize_tool_call/1)
          tool_results = execute_tool_calls(tool_calls, state)

          # Build next context: response.context already has assistant message,
          # append tool results using ReqLLM's format
          next_context = append_tool_results(response.context, tool_calls, tool_results)
          llm_call_loop(llm_model, system_prompt, next_context, state, max_rounds, round + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Tool call normalization --

  defp normalize_tool_call(tc) do
    input =
      case Jason.decode(tc.function.arguments) do
        {:ok, decoded} -> decoded
        # coveralls-ignore-next-line
        {:error, _} -> %{"_raw" => tc.function.arguments}
      end

    %{
      tool_use_id: tc.id,
      name: tc.function.name,
      input: input
    }
  end

  # -- Tool execution --

  defp execute_tool_calls(tool_calls, state) do
    tool_servers = state[:tool_servers] || %{}
    user_id = state[:user_id]

    Enum.map(tool_calls, fn tc ->
      server = Map.get(tool_servers, tc.name)
      ToolUtils.execute_tool(server, tc.name, tc.input, user_id: user_id)
    end)
  end

  # -- Context building for tool results --

  defp append_tool_results(llm_context, tool_calls, tool_results) do
    tool_result_messages =
      Enum.zip(tool_calls, tool_results)
      |> Enum.map(fn {tc, result} ->
        ReqLLM.Context.tool_result(tc.tool_use_id, tc.name, ToolUtils.format_tool_output(result))
      end)

    Enum.reduce(tool_result_messages, llm_context, &ReqLLM.Context.append(&2, &1))
  end

  # -- Context serialization for logging --

  defp serialize_context(system_prompt, context) do
    system_msg = %{"role" => "system", "content" => system_prompt}
    context_msgs = context.messages |> Jason.encode!() |> Jason.decode!()
    [system_msg | context_msgs]
  end
end
