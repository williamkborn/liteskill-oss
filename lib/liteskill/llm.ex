defmodule Liteskill.LLM do
  @moduledoc """
  Public API for LLM interactions.

  Uses ReqLLM for transport. `complete/2` is used for non-streaming calls
  (e.g. conversation title generation). Streaming is handled by
  `StreamHandler` directly.

  Models are configured in the database via admin UI — there are no
  hardcoded model IDs or env-var fallbacks for model selection.
  """

  alias Liteskill.LLM.StreamHandler
  alias Liteskill.Usage
  alias Liteskill.Usage.CostCalculator

  require Logger

  @doc """
  Sends a non-streaming completion request.

  Requires either `:llm_model` (a `%LlmModel{}` struct) or `:model_id` +
  `:provider_options` to be passed in opts.

  ## Options
    - `:llm_model` - A `%LlmModel{}` struct with full provider config
    - `:model_id` - Model ID string (requires `:provider_options` too)
    - `:max_tokens` - Maximum tokens to generate
    - `:temperature` - Sampling temperature
    - `:system` - System prompt
    - `:generate_fn` - Override the generation function (for testing)
  """
  def complete(messages, opts \\ []) do
    llm_model = Keyword.get(opts, :llm_model)

    {model, req_opts} =
      if llm_model do
        {model_spec, model_opts} = Liteskill.LlmModels.build_provider_options(llm_model)
        {model_spec, model_opts}
      else
        model_id =
          Keyword.get(opts, :model_id) ||
            raise "No model specified: pass :llm_model or :model_id option"

        provider_opts = Keyword.get(opts, :provider_options, [])
        {StreamHandler.to_req_llm_model(model_id), [provider_options: provider_opts]}
      end

    context = StreamHandler.to_req_llm_context(messages)

    req_opts =
      case Keyword.get(opts, :system) do
        nil -> req_opts
        system -> Keyword.put(req_opts, :system_prompt, system)
      end

    req_opts =
      case Keyword.get(opts, :temperature) do
        nil -> req_opts
        temp -> Keyword.put(req_opts, :temperature, temp)
      end

    req_opts =
      case Keyword.get(opts, :max_tokens) do
        nil -> req_opts
        max -> Keyword.put(req_opts, :max_tokens, max)
      end

    generate_fn = Keyword.get(opts, :generate_fn, &default_generate/3)

    case generate_fn.(model, context, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        maybe_record_complete_usage(response, model, opts)

        {:ok,
         %{"output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => text}]}}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # coveralls-ignore-start
  defp default_generate(model, context, opts) do
    ReqLLM.generate_text(model, context, opts)
  end

  # coveralls-ignore-stop

  defp maybe_record_complete_usage(response, model, opts) do
    user_id = Keyword.get(opts, :user_id)

    if user_id do
      usage = ReqLLM.Response.usage(response) || %{}
      model_id = if is_map(model), do: model[:id], else: to_string(model)

      llm_model = Keyword.get(opts, :llm_model)

      llm_model_id =
        case llm_model do
          %{id: id} -> id
          _ -> nil
        end

      input_tokens = usage[:input_tokens] || 0
      output_tokens = usage[:output_tokens] || 0

      {input_cost, output_cost, total_cost} =
        CostCalculator.resolve_costs(usage, llm_model, input_tokens, output_tokens)

      attrs = %{
        user_id: user_id,
        conversation_id: Keyword.get(opts, :conversation_id),
        model_id: model_id || "unknown",
        llm_model_id: llm_model_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: usage[:total_tokens] || 0,
        reasoning_tokens: usage[:reasoning_tokens] || 0,
        cached_tokens: usage[:cached_tokens] || 0,
        cache_creation_tokens: usage[:cache_creation_tokens] || 0,
        input_cost: input_cost,
        output_cost: output_cost,
        reasoning_cost: CostCalculator.to_decimal(usage[:reasoning_cost]),
        total_cost: total_cost,
        call_type: "complete"
      }

      case Usage.record_usage(attrs) do
        {:ok, _} ->
          :ok

        # coveralls-ignore-start
        {:error, changeset} ->
          Logger.warning("Failed to record usage: #{inspect(changeset.errors)}")
          # coveralls-ignore-stop
      end
    end
  end

  @doc """
  Returns active LLM models available to the given user (DB-only).
  """
  def available_models(user_id) do
    Liteskill.LlmModels.list_active_models(user_id, model_type: "inference")
  end
end
