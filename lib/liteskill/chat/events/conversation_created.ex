defmodule Liteskill.Chat.Events.ConversationCreated do
  @derive Jason.Encoder
  defstruct [:conversation_id, :user_id, :title, :model_id, :system_prompt, :llm_model_id]
end
