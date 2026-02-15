defmodule Liteskill.UsageTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Usage
  alias Liteskill.Usage.UsageRecord

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "usage-test-#{System.unique_integer([:positive])}@example.com",
        name: "Usage Test",
        oidc_sub: "usage-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, conv} =
      Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Usage Test Conv"})

    %{user: user, conversation: conv}
  end

  defp valid_attrs(user, conv, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        conversation_id: conv.id,
        model_id: "us.anthropic.claude-3-5-sonnet",
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        reasoning_tokens: 0,
        cached_tokens: 10,
        cache_creation_tokens: 5,
        input_cost: Decimal.new("0.003"),
        output_cost: Decimal.new("0.0075"),
        total_cost: Decimal.new("0.0105"),
        latency_ms: 1200,
        call_type: "stream",
        tool_round: 0
      },
      overrides
    )
  end

  describe "record_usage/1" do
    test "inserts a usage record with valid attrs", %{user: user, conversation: conv} do
      assert {:ok, %UsageRecord{} = record} = Usage.record_usage(valid_attrs(user, conv))

      assert record.user_id == user.id
      assert record.conversation_id == conv.id
      assert record.model_id == "us.anthropic.claude-3-5-sonnet"
      assert record.input_tokens == 100
      assert record.output_tokens == 50
      assert record.total_tokens == 150
      assert record.call_type == "stream"
    end

    test "requires user_id", %{conversation: conv} do
      attrs = %{model_id: "test", call_type: "stream", conversation_id: conv.id}
      assert {:error, changeset} = Usage.record_usage(attrs)
      assert errors_on(changeset).user_id
    end

    test "requires model_id", %{user: user} do
      attrs = %{user_id: user.id, call_type: "stream"}
      assert {:error, changeset} = Usage.record_usage(attrs)
      assert errors_on(changeset).model_id
    end

    test "requires call_type", %{user: user} do
      attrs = %{user_id: user.id, model_id: "test"}
      assert {:error, changeset} = Usage.record_usage(attrs)
      assert errors_on(changeset).call_type
    end

    test "validates call_type inclusion", %{user: user} do
      attrs = %{user_id: user.id, model_id: "test", call_type: "invalid"}
      assert {:error, changeset} = Usage.record_usage(attrs)
      assert errors_on(changeset).call_type
    end

    test "allows nil conversation_id", %{user: user} do
      attrs = %{user_id: user.id, model_id: "test", call_type: "complete"}
      assert {:ok, %UsageRecord{conversation_id: nil}} = Usage.record_usage(attrs)
    end
  end

  describe "usage_by_conversation/1" do
    test "returns aggregated usage for a conversation", %{user: user, conversation: conv} do
      Usage.record_usage(
        valid_attrs(user, conv, %{input_tokens: 100, output_tokens: 50, total_tokens: 150})
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{input_tokens: 200, output_tokens: 100, total_tokens: 300})
      )

      result = Usage.usage_by_conversation(conv.id)

      assert result.input_tokens == 300
      assert result.output_tokens == 150
      assert result.total_tokens == 450
      assert result.call_count == 2
    end

    test "returns zeros for conversation with no usage", %{conversation: _conv} do
      result = Usage.usage_by_conversation(Ecto.UUID.generate())

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
      assert result.call_count == 0
    end
  end

  describe "usage_by_user/2" do
    test "returns aggregated usage for a user", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{input_tokens: 100, total_tokens: 150}))
      Usage.record_usage(valid_attrs(user, conv, %{input_tokens: 200, total_tokens: 300}))

      result = Usage.usage_by_user(user.id)

      assert result.input_tokens == 300
      assert result.total_tokens == 450
      assert result.call_count == 2
    end

    test "filters by time range", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      # Query with future :from — should find nothing
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Usage.usage_by_user(user.id, from: future)

      assert result.call_count == 0

      # Query with past :from — should find the record
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Usage.usage_by_user(user.id, from: past)

      assert result.call_count == 1
    end

    test "filters with :to", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      # to in the past — should find nothing
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Usage.usage_by_user(user.id, to: past)

      assert result.call_count == 0

      # to in the future — should find the record
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Usage.usage_by_user(user.id, to: future)

      assert result.call_count == 1
    end
  end

  describe "usage_by_user_and_model/2" do
    test "returns usage grouped by model", %{user: user, conversation: conv} do
      Usage.record_usage(
        valid_attrs(user, conv, %{model_id: "model-a", input_tokens: 100, total_tokens: 100})
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{model_id: "model-a", input_tokens: 200, total_tokens: 200})
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{model_id: "model-b", input_tokens: 50, total_tokens: 50})
      )

      results = Usage.usage_by_user_and_model(user.id)

      assert length(results) == 2

      model_a = Enum.find(results, &(&1.model_id == "model-a"))
      assert model_a.input_tokens == 300
      assert model_a.call_count == 2

      model_b = Enum.find(results, &(&1.model_id == "model-b"))
      assert model_b.input_tokens == 50
      assert model_b.call_count == 1
    end
  end

  describe "usage_summary/1" do
    test "returns aggregate without grouping", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{input_tokens: 100, total_tokens: 150}))

      result = Usage.usage_summary(user_id: user.id)

      assert result.input_tokens == 100
      assert result.total_tokens == 150
      assert result.call_count == 1
    end

    test "groups by model_id", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "m1", total_tokens: 100}))
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "m2", total_tokens: 200}))

      results = Usage.usage_summary(user_id: user.id, group_by: :model_id)

      assert length(results) == 2
      assert Enum.any?(results, &(&1.model_id == "m1"))
    end

    test "groups by user_id", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      results = Usage.usage_summary(group_by: :user_id)

      assert is_list(results)
      assert Enum.any?(results, &(&1.user_id == user.id))
    end

    test "groups by conversation_id", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      results = Usage.usage_summary(group_by: :conversation_id)

      assert is_list(results)
      assert Enum.any?(results, &(&1.conversation_id == conv.id))
    end

    test "filters by model_id", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "target-model", total_tokens: 100}))
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "other-model", total_tokens: 200}))

      result = Usage.usage_summary(model_id: "target-model")

      assert result.total_tokens == 100
      assert result.call_count == 1
    end

    test "filters by conversation_id", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      result = Usage.usage_summary(conversation_id: conv.id)

      assert result.call_count == 1
    end

    test "combines filters", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "m1"}))
      Usage.record_usage(valid_attrs(user, conv, %{model_id: "m2"}))

      result = Usage.usage_summary(user_id: user.id, model_id: "m1")

      assert result.call_count == 1
    end
  end

  describe "usage_by_group/2" do
    test "aggregates usage for all group members", %{user: user, conversation: conv} do
      {:ok, user2} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "group-member-#{System.unique_integer([:positive])}@example.com",
          name: "Group Member",
          oidc_sub: "group-member-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, group} = Liteskill.Groups.create_group("test-group", user.id)
      {:ok, _} = Liteskill.Groups.admin_add_member(group.id, user2.id, "member")

      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))

      {:ok, conv2} =
        Liteskill.Chat.create_conversation(%{user_id: user2.id, title: "Conv 2"})

      Usage.record_usage(valid_attrs(user2, conv2, %{total_tokens: 200}))

      result = Usage.usage_by_group(group.id)

      assert result.total_tokens == 300
      assert result.call_count == 2
    end

    test "returns zeros for group with no usage", %{user: user} do
      {:ok, group} = Liteskill.Groups.create_group("empty-group", user.id)

      result = Usage.usage_by_group(group.id)

      assert result.total_tokens == 0
      assert result.call_count == 0
    end

    test "filters by time range", %{user: user, conversation: conv} do
      {:ok, group} = Liteskill.Groups.create_group("time-group", user.id)

      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Usage.usage_by_group(group.id, from: future)

      assert result.call_count == 0

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Usage.usage_by_group(group.id, from: past)

      assert result.call_count == 1
    end
  end

  describe "usage_by_groups/2" do
    test "returns batch usage for multiple groups", %{user: user, conversation: conv} do
      {:ok, user2} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "batch-member-#{System.unique_integer([:positive])}@example.com",
          name: "Batch Member",
          oidc_sub: "batch-member-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, group1} = Liteskill.Groups.create_group("batch-group-1", user.id)
      {:ok, group2} = Liteskill.Groups.create_group("batch-group-2", user.id)
      {:ok, _} = Liteskill.Groups.admin_add_member(group2.id, user2.id, "member")

      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))

      {:ok, conv2} =
        Liteskill.Chat.create_conversation(%{user_id: user2.id, title: "Batch Conv"})

      Usage.record_usage(valid_attrs(user2, conv2, %{total_tokens: 200}))

      result = Usage.usage_by_groups([group1.id, group2.id])

      assert is_map(result)
      assert map_size(result) == 2

      # group1 has user (owner/creator) with 100 tokens
      assert result[group1.id].total_tokens == 100

      # group2 has user (creator, 100 tokens) + user2 (member, 200 tokens) = 300
      assert result[group2.id].total_tokens == 300
    end

    test "returns zeroed values for groups with no usage", %{user: user} do
      {:ok, group} = Liteskill.Groups.create_group("empty-batch-group", user.id)

      result = Usage.usage_by_groups([group.id])

      assert result[group.id].total_tokens == 0
      assert result[group.id].call_count == 0
    end

    test "returns empty map for empty group_ids list" do
      assert Usage.usage_by_groups([]) == %{}
    end

    test "respects time filters", %{user: user, conversation: conv} do
      {:ok, group} = Liteskill.Groups.create_group("time-batch-group", user.id)

      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Usage.usage_by_groups([group.id], from: future)

      assert result[group.id].total_tokens == 0
      assert result[group.id].call_count == 0
    end
  end

  describe "usage_by_run/1" do
    setup %{user: user} do
      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Usage Test Run",
          prompt: "test prompt",
          user_id: user.id
        })

      %{run: run}
    end

    test "returns aggregated usage for a run", %{user: user, conversation: conv, run: run} do
      Usage.record_usage(
        valid_attrs(user, conv, %{run_id: run.id, input_tokens: 100, total_tokens: 150})
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{run_id: run.id, input_tokens: 200, total_tokens: 300})
      )

      # Record outside this run — should not be counted
      Usage.record_usage(valid_attrs(user, conv, %{input_tokens: 999, total_tokens: 999}))

      result = Usage.usage_by_run(run.id)

      assert result.input_tokens == 300
      assert result.output_tokens == 100
      assert result.total_tokens == 450
      assert result.call_count == 2
    end

    test "returns zeros for run with no usage", %{user: user} do
      {:ok, empty_run} =
        Liteskill.Runs.create_run(%{
          name: "Empty Run",
          prompt: "no usage",
          user_id: user.id
        })

      result = Usage.usage_by_run(empty_run.id)

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
      assert result.call_count == 0
    end
  end

  describe "usage_by_run_and_model/1" do
    setup %{user: user} do
      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Model Usage Test Run",
          prompt: "test prompt",
          user_id: user.id
        })

      %{run: run}
    end

    test "returns usage grouped by model for a run", %{
      user: user,
      conversation: conv,
      run: run
    } do
      Usage.record_usage(
        valid_attrs(user, conv, %{
          run_id: run.id,
          model_id: "model-a",
          input_tokens: 100,
          total_tokens: 100
        })
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{
          run_id: run.id,
          model_id: "model-a",
          input_tokens: 200,
          total_tokens: 200
        })
      )

      Usage.record_usage(
        valid_attrs(user, conv, %{
          run_id: run.id,
          model_id: "model-b",
          input_tokens: 50,
          total_tokens: 50
        })
      )

      results = Usage.usage_by_run_and_model(run.id)

      assert length(results) == 2

      # Ordered by total_tokens desc
      [first | _] = results
      assert first.model_id == "model-a"
      assert first.input_tokens == 300
      assert first.call_count == 2

      model_b = Enum.find(results, &(&1.model_id == "model-b"))
      assert model_b.input_tokens == 50
      assert model_b.call_count == 1
    end

    test "returns empty list for run with no usage", %{user: user} do
      {:ok, empty_run} =
        Liteskill.Runs.create_run(%{
          name: "Empty Model Run",
          prompt: "no usage",
          user_id: user.id
        })

      assert [] == Usage.usage_by_run_and_model(empty_run.id)
    end
  end

  describe "instance_totals/1" do
    test "returns instance-wide totals", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100, input_tokens: 60}))
      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 200, input_tokens: 120}))

      result = Usage.instance_totals()

      assert result.total_tokens >= 300
      assert result.input_tokens >= 180
      assert result.call_count >= 2
    end

    test "filters by time range", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Usage.instance_totals(from: future)

      assert result.call_count == 0
    end
  end

  describe "daily_totals/1" do
    test "returns daily aggregated usage", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))
      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 200}))

      results = Usage.daily_totals()

      assert is_list(results)
      assert length(results) >= 1

      today = Enum.find(results, fn d -> d.total_tokens >= 300 end)
      assert today
      assert today.call_count >= 2
    end

    test "respects time filters", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv))

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      results = Usage.daily_totals(from: future)

      assert results == []
    end

    test "respects user_id filter", %{user: user, conversation: conv} do
      Usage.record_usage(valid_attrs(user, conv, %{total_tokens: 100}))

      results = Usage.daily_totals(user_id: user.id)

      assert length(results) >= 1
      total = Enum.reduce(results, 0, fn d, acc -> acc + d.total_tokens end)
      assert total >= 100

      # Non-existent user should get nothing
      results = Usage.daily_totals(user_id: Ecto.UUID.generate())
      assert results == []
    end
  end
end
