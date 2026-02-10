defmodule Liteskill.LLM.EventStreamParserTest do
  use ExUnit.Case, async: true

  alias Liteskill.LLM.EventStreamParser

  describe "parse/1" do
    test "parses a complete contentBlockDelta message" do
      message =
        build_event_stream_message("contentBlockDelta", %{"delta" => %{"text" => "Hello"}})

      {events, remaining} = EventStreamParser.parse(message)

      assert length(events) == 1
      assert {:content_block_delta, %{"delta" => %{"text" => "Hello"}}} = Enum.at(events, 0)
      assert remaining == <<>>
    end

    test "parses multiple messages" do
      msg1 = build_event_stream_message("messageStart", %{"role" => "assistant"})
      msg2 = build_event_stream_message("contentBlockDelta", %{"delta" => %{"text" => "Hi"}})

      {events, remaining} = EventStreamParser.parse(msg1 <> msg2)

      assert length(events) == 2
      assert {:message_start, _} = Enum.at(events, 0)
      assert {:content_block_delta, _} = Enum.at(events, 1)
      assert remaining == <<>>
    end

    test "handles partial message (returns remaining buffer)" do
      message = build_event_stream_message("messageStart", %{"role" => "assistant"})
      partial = binary_part(message, 0, byte_size(message) - 4)

      {events, remaining} = EventStreamParser.parse(partial)

      assert events == []
      assert byte_size(remaining) > 0
    end

    test "handles empty buffer" do
      {events, remaining} = EventStreamParser.parse(<<>>)
      assert events == []
      assert remaining == <<>>
    end

    test "handles buffer too small for prelude" do
      {events, remaining} = EventStreamParser.parse(<<1, 2, 3>>)
      assert events == []
      assert remaining == <<1, 2, 3>>
    end

    test "parses messageStop event" do
      message = build_event_stream_message("messageStop", %{"stopReason" => "end_turn"})
      {events, _} = EventStreamParser.parse(message)

      assert [{:message_stop, %{"stopReason" => "end_turn"}}] = events
    end

    test "parses metadata event" do
      message =
        build_event_stream_message("metadata", %{
          "usage" => %{"inputTokens" => 10, "outputTokens" => 5}
        })

      {events, _} = EventStreamParser.parse(message)
      assert [{:metadata, %{"usage" => _}}] = events
    end

    test "parses contentBlockStart event" do
      message =
        build_event_stream_message("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{"type" => "text"}
        })

      {events, _} = EventStreamParser.parse(message)
      assert [{:content_block_start, _}] = events
    end

    test "parses contentBlockStop event" do
      message = build_event_stream_message("contentBlockStop", %{"contentBlockIndex" => 0})
      {events, _} = EventStreamParser.parse(message)
      assert [{:content_block_stop, _}] = events
    end

    test "skips empty payload messages" do
      # Build a message with empty payload
      headers = build_headers("someEvent")
      headers_length = byte_size(headers)
      payload = <<>>
      total_length = 16 + headers_length + 0

      prelude = <<total_length::32-big, headers_length::32-big>>
      prelude_crc = :erlang.crc32(prelude)

      message_without_crc = <<
        prelude::binary,
        prelude_crc::32-big,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)
      message = <<message_without_crc::binary, message_crc::32-big>>

      {events, _} = EventStreamParser.parse(message)
      assert events == []
    end

    test "skips messages with invalid JSON payload" do
      headers = build_headers("someEvent")
      headers_length = byte_size(headers)
      payload = "not valid json"
      payload_length = byte_size(payload)
      total_length = 16 + headers_length + payload_length

      prelude = <<total_length::32-big, headers_length::32-big>>
      prelude_crc = :erlang.crc32(prelude)

      message_without_crc = <<
        prelude::binary,
        prelude_crc::32-big,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)
      message = <<message_without_crc::binary, message_crc::32-big>>

      {events, _} = EventStreamParser.parse(message)
      assert events == []
    end

    test "handles unknown event type safely without atom creation" do
      message = build_event_stream_message("customEvent", %{"data" => "value"})
      {events, _} = EventStreamParser.parse(message)
      assert [{:unknown, %{"data" => "value"}}] = events
    end

    test "handles headers without :event-type" do
      # Build a message with no headers (empty headers section)
      headers = <<>>
      headers_length = 0
      payload = Jason.encode!(%{"test" => true})
      payload_length = byte_size(payload)
      total_length = 16 + headers_length + payload_length

      prelude = <<total_length::32-big, headers_length::32-big>>
      prelude_crc = :erlang.crc32(prelude)

      message_without_crc = <<
        prelude::binary,
        prelude_crc::32-big,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)
      message = <<message_without_crc::binary, message_crc::32-big>>

      {events, _} = EventStreamParser.parse(message)
      # Should parse with "unknown" event type
      assert [{:unknown, %{"test" => true}}] = events
    end

    test "handles headers with non-string type (falls through to catch-all)" do
      # Build headers where the type byte is not 7 (string type)
      name = ":event-type"
      value = "test"

      # Use type 0 instead of 7
      headers =
        <<byte_size(name)::8, name::binary, 0::8, byte_size(value)::16-big, value::binary>>

      headers_length = byte_size(headers)
      payload = Jason.encode!(%{"data" => true})
      payload_length = byte_size(payload)
      total_length = 16 + headers_length + payload_length

      prelude = <<total_length::32-big, headers_length::32-big>>
      prelude_crc = :erlang.crc32(prelude)

      message_without_crc = <<
        prelude::binary,
        prelude_crc::32-big,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)
      message = <<message_without_crc::binary, message_crc::32-big>>

      {events, _} = EventStreamParser.parse(message)
      # Should use "unknown" since header type doesn't match the pattern
      assert [{:unknown, _}] = events
    end
  end

  # Build a minimal AWS event-stream message for testing
  defp build_event_stream_message(event_type, payload) do
    payload_json = Jason.encode!(payload)
    headers = build_headers(event_type)
    headers_length = byte_size(headers)
    payload_length = byte_size(payload_json)
    total_length = 16 + headers_length + payload_length

    prelude = <<total_length::32-big, headers_length::32-big>>
    prelude_crc = :erlang.crc32(prelude)

    message_without_crc = <<
      prelude::binary,
      prelude_crc::32-big,
      headers::binary,
      payload_json::binary
    >>

    message_crc = :erlang.crc32(message_without_crc)

    <<message_without_crc::binary, message_crc::32-big>>
  end

  defp build_headers(event_type) do
    name = ":event-type"
    <<byte_size(name)::8, name::binary, 7::8, byte_size(event_type)::16-big, event_type::binary>>
  end
end
