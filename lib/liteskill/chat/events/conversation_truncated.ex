defmodule Liteskill.Chat.Events.ConversationTruncated do
  @moduledoc """
  Event emitted when a conversation is truncated at a specific message.

  All messages after the target message (exclusive) are removed.
  """

  defstruct [:message_id, :timestamp]
end
