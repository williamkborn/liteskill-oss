defmodule Liteskill.LLM.EventStreamParser do
  @moduledoc """
  Parser for AWS event-stream binary encoding.

  Bedrock ConverseStream returns binary framed messages, not JSON lines.
  Each message has the format:
    - 4 bytes: total byte length (big-endian)
    - 4 bytes: headers byte length (big-endian)
    - 4 bytes: prelude CRC32 checksum
    - N bytes: headers
    - M bytes: payload (JSON)
    - 4 bytes: message CRC32 checksum
  """

  @doc """
  Parses a binary buffer into a list of `{event_type, json_payload}` tuples
  and returns any remaining unparsed bytes.

  Returns `{parsed_events, remaining_buffer}`.
  """
  def parse(buffer) do
    parse_messages(buffer, [])
  end

  defp parse_messages(buffer, acc) when byte_size(buffer) < 12 do
    {Enum.reverse(acc), buffer}
  end

  defp parse_messages(
         <<total_length::32-big, headers_length::32-big, _prelude_crc::32-big, rest::binary>> =
           buffer,
         acc
       ) do
    payload_length = total_length - headers_length - 16
    needed = total_length - 12

    if byte_size(rest) >= needed do
      <<headers_bin::binary-size(headers_length), payload::binary-size(payload_length),
        _message_crc::32-big, remaining::binary>> = rest

      event_type = extract_event_type(headers_bin)
      event = parse_payload(event_type, payload)

      case event do
        nil -> parse_messages(remaining, acc)
        event -> parse_messages(remaining, [event | acc])
      end
    else
      {Enum.reverse(acc), buffer}
    end
  end

  # coveralls-ignore-start
  defp parse_messages(buffer, acc) do
    {Enum.reverse(acc), buffer}
  end

  # coveralls-ignore-stop

  defp extract_event_type(headers_bin) do
    parse_headers(headers_bin)
    |> Map.get(":event-type", "unknown")
  end

  defp parse_headers(<<>>), do: %{}

  defp parse_headers(bin) do
    parse_headers(bin, %{})
  end

  defp parse_headers(<<>>, acc), do: acc

  defp parse_headers(
         <<name_len::8, name::binary-size(name_len), 7::8, value_len::16-big,
           value::binary-size(value_len), rest::binary>>,
         acc
       ) do
    parse_headers(rest, Map.put(acc, name, value))
  end

  defp parse_headers(_bin, acc), do: acc

  defp parse_payload(_event_type, <<>>), do: nil

  defp parse_payload(event_type, payload) do
    case Jason.decode(payload) do
      {:ok, data} -> {event_type_atom(event_type), data}
      _ -> nil
    end
  end

  @known_event_types %{
    "messageStart" => :message_start,
    "contentBlockStart" => :content_block_start,
    "contentBlockDelta" => :content_block_delta,
    "contentBlockStop" => :content_block_stop,
    "messageStop" => :message_stop,
    "metadata" => :metadata
  }

  defp event_type_atom(event_type) do
    Map.get(@known_event_types, event_type, :unknown)
  end
end
