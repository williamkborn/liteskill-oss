defmodule Liteskill.LLM.StreamHandlerTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.LLM.StreamHandler

  setup do
    Application.put_env(:liteskill, Liteskill.LLM,
      bedrock_region: "us-east-1",
      bedrock_model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
      bedrock_bearer_token: "test-token"
    )

    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "stream-test-#{System.unique_integer([:positive])}@example.com",
        name: "Stream Test",
        oidc_sub: "stream-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Stream Test"})
    {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello!")

    on_exit(fn -> Process.sleep(200) end)

    %{user: user, conversation: conv}
  end

  test "successful stream with completion", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn
      |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id
    messages = [%{role: :user, content: "test"}]

    assert :ok =
             StreamHandler.handle_stream(stream_id, messages,
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamCompleted" in event_types
  end

  test "stream request error records AssistantStreamFailed", %{conversation: conv} do
    stream_id = conv.stream_id
    messages = [%{role: :user, content: "test"}]

    # Without a Req.Test stub or valid config, the HTTP call will fail
    _result = StreamHandler.handle_stream(stream_id, messages)

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamFailed" in event_types
  end

  test "handle_stream fails when conversation is archived", %{user: user} do
    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Archive Test"})
    {:ok, _} = Chat.archive_conversation(conv.id, user.id)

    assert {:error, :conversation_archived} =
             StreamHandler.handle_stream(conv.stream_id, [%{role: :user, content: "test"}])
  end

  test "passes model_id option", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
      model_id: "custom-model",
      plug: {Req.Test, Liteskill.LLM.BedrockClient}
    )

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)

    started_events =
      Enum.filter(events, &(&1.event_type == "AssistantStreamStarted"))

    last_started = List.last(started_events)
    assert last_started.data["model_id"] == "custom-model"
  end

  test "passes system prompt option", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               system: "Be brief",
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    Process.sleep(200)
  end

  test "stream completion records full_content and stop_reason", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)
    completed = Enum.find(events, &(&1.event_type == "AssistantStreamCompleted"))
    assert completed != nil
    assert completed.data["full_content"] == ""
    assert completed.data["stop_reason"] == "end_turn"
  end

  test "retries on 503 with backoff then succeeds", %{conversation: conv} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      count = Agent.get_and_update(counter, &{&1, &1 + 1})

      if count < 1 do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"message" => "unavailable"}))
      else
        conn |> Plug.Conn.send_resp(200, "")
      end
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               backoff_ms: 1
             )

    Process.sleep(200)
    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "fails after max retries exceeded", %{conversation: conv} do
    # Always return 503 to exhaust retries
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "rate limited"}))
    end)

    stream_id = conv.stream_id

    assert {:error, {"max_retries_exceeded", _}} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               backoff_ms: 1
             )

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamFailed" in event_types

    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed.data["error_type"] == "max_retries_exceeded"
  end

  test "stream with tools option passes toolConfig in request body", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      # Verify toolConfig is present
      assert decoded["toolConfig"] != nil
      assert decoded["toolConfig"]["tools"] != nil
      assert length(decoded["toolConfig"]["tools"]) == 1

      tool = hd(decoded["toolConfig"]["tools"])
      assert tool["toolSpec"]["name"] == "get_weather"

      conn |> Plug.Conn.send_resp(200, "")
    end)

    tools = [
      %{
        "toolSpec" => %{
          "name" => "get_weather",
          "description" => "Get weather",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }
    ]

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               tools: tools
             )

    Process.sleep(200)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "returns error when max tool rounds exceeded", %{conversation: conv} do
    stream_id = conv.stream_id

    # Simulate being at the max tool round limit
    assert {:error, :max_tool_rounds_exceeded} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               tool_round: 10,
               max_tool_rounds: 10
             )
  end

  test "allows stream when under max tool rounds", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               tool_round: 5,
               max_tool_rounds: 10,
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    Process.sleep(200)
  end

  test "stream without tools does not include toolConfig", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      # No toolConfig when no tools
      assert decoded["toolConfig"] == nil

      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    Process.sleep(200)
  end
end
