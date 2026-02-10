defmodule Liteskill.Chat do
  @moduledoc """
  The Chat context. Provides write and read APIs for conversations.

  Write path: Context -> Aggregate -> EventStore -> PubSub -> Projector
  Read path: Context -> Ecto queries on projection tables
  """

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Chat.{Conversation, ConversationAcl, ConversationAggregate, Message, Projector}
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.Groups.GroupMembership
  alias Liteskill.Repo

  import Ecto.Query

  # --- Write API ---

  def create_conversation(params) do
    conversation_id = params[:conversation_id] || Ecto.UUID.generate()
    stream_id = "conversation-#{conversation_id}"

    command =
      {:create_conversation,
       %{
         conversation_id: conversation_id,
         user_id: params.user_id,
         title: params[:title] || "New Conversation",
         model_id: params[:model_id] || default_model_id(),
         system_prompt: params[:system_prompt]
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        Process.sleep(50)
        conversation = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)

        # Auto-create owner ACL
        %ConversationAcl{}
        |> ConversationAcl.changeset(%{
          conversation_id: conversation.id,
          user_id: params.user_id,
          role: "owner"
        })
        |> Repo.insert!()

        {:ok, conversation}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(conversation_id, user_id, content) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      stream_id = conversation.stream_id
      message_id = Ecto.UUID.generate()

      command = {:add_user_message, %{message_id: message_id, content: content}}

      case Loader.execute(ConversationAggregate, stream_id, command) do
        {:ok, _state, events} ->
          Projector.project_events(stream_id, events)
          Process.sleep(50)
          {:ok, Repo.get!(Message, message_id)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def fork_conversation(conversation_id, user_id, at_message_position) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      parent_stream_id = conversation.stream_id

      # Read parent events up to the fork point
      parent_events = Store.read_stream_forward(parent_stream_id)

      # Find the stream_version that corresponds to the message at the given position
      fork_at_version = find_version_at_position(parent_events, at_message_position)

      events_to_copy = Enum.filter(parent_events, &(&1.stream_version <= fork_at_version))

      # Create new stream
      new_conversation_id = Ecto.UUID.generate()
      new_stream_id = "conversation-#{new_conversation_id}"

      # Build fork event + copied events
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      fork_event = %{
        event_type: "ConversationForked",
        data: %{
          "new_conversation_id" => new_conversation_id,
          "parent_stream_id" => parent_stream_id,
          "fork_at_version" => fork_at_version,
          "user_id" => conversation.user_id,
          "timestamp" => now
        }
      }

      {copied_events, _id_map} =
        Enum.map_reduce(events_to_copy, %{}, fn event, id_map ->
          {data, id_map} = remap_event_data(event, new_conversation_id, id_map)
          {%{event_type: event.event_type, data: data, metadata: event.metadata}, id_map}
        end)

      # ConversationCreated must come first so the projection exists
      # before ConversationForked tries to update it
      all_events = copied_events ++ [fork_event]

      case Store.append_events(new_stream_id, 0, all_events) do
        {:ok, stored_events} ->
          Projector.project_events(new_stream_id, stored_events)
          Process.sleep(50)
          new_conv = Repo.one!(from c in Conversation, where: c.stream_id == ^new_stream_id)

          # Auto-create owner ACL for forked conversation
          %ConversationAcl{}
          |> ConversationAcl.changeset(%{
            conversation_id: new_conv.id,
            user_id: user_id,
            role: "owner"
          })
          |> Repo.insert!()

          {:ok, new_conv}

        # coveralls-ignore-next-line
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def archive_conversation(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      case Loader.execute(ConversationAggregate, conversation.stream_id, {:archive, %{}}) do
        {:ok, _state, events} ->
          Projector.project_events(conversation.stream_id, events)
          Process.sleep(50)
          {:ok, Repo.get!(Conversation, conversation_id)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update_title(conversation_id, user_id, title) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      case Loader.execute(
             ConversationAggregate,
             conversation.stream_id,
             {:update_title, %{title: title}}
           ) do
        {:ok, _state, events} ->
          Projector.project_events(conversation.stream_id, events)
          Process.sleep(50)
          {:ok, Repo.get!(Conversation, conversation_id)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- ACL Management ---

  def grant_conversation_access(conversation_id, grantor_id, grantee_user_id, role \\ "member") do
    with {:ok, _conv} <- authorize_owner(conversation_id, grantor_id) do
      %ConversationAcl{}
      |> ConversationAcl.changeset(%{
        conversation_id: conversation_id,
        user_id: grantee_user_id,
        role: role
      })
      |> Repo.insert()
    end
  end

  def revoke_conversation_access(conversation_id, revoker_id, target_user_id) do
    with {:ok, _conv} <- authorize_owner(conversation_id, revoker_id) do
      case Repo.one(
             from a in ConversationAcl,
               where: a.conversation_id == ^conversation_id and a.user_id == ^target_user_id
           ) do
        nil ->
          {:error, :not_found}

        %ConversationAcl{role: "owner"} ->
          {:error, :cannot_revoke_owner}

        acl ->
          Repo.delete(acl)
      end
    end
  end

  def leave_conversation(conversation_id, user_id) do
    case Repo.one(
           from a in ConversationAcl,
             where: a.conversation_id == ^conversation_id and a.user_id == ^user_id
         ) do
      nil ->
        {:error, :not_found}

      %ConversationAcl{role: "owner"} ->
        {:error, :owner_cannot_leave}

      acl ->
        Repo.delete(acl)
    end
  end

  def grant_group_access(conversation_id, grantor_id, group_id, role \\ "member") do
    with {:ok, _conv} <- authorize_owner(conversation_id, grantor_id) do
      %ConversationAcl{}
      |> ConversationAcl.changeset(%{
        conversation_id: conversation_id,
        group_id: group_id,
        role: role
      })
      |> Repo.insert()
    end
  end

  # --- Read API ---

  def list_conversations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    direct_acl_subquery =
      from a in ConversationAcl,
        where: a.user_id == ^user_id,
        select: a.conversation_id

    group_acl_subquery =
      from a in ConversationAcl,
        join: gm in GroupMembership,
        on: gm.group_id == a.group_id and gm.user_id == ^user_id,
        where: not is_nil(a.group_id),
        select: a.conversation_id

    Conversation
    |> where(
      [c],
      c.user_id == ^user_id or
        c.id in subquery(direct_acl_subquery) or
        c.id in subquery(group_acl_subquery)
    )
    |> where([c], c.status != "archived")
    |> order_by([c], desc: c.updated_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def get_conversation(id, user_id) do
    case Repo.get(Conversation, id) do
      nil ->
        {:error, :not_found}

      conversation ->
        if has_access?(conversation, user_id) do
          {:ok,
           Repo.preload(conversation,
             messages: from(m in Message, order_by: [asc: m.position])
           )}
        else
          {:error, :not_found}
        end
    end
  end

  def list_messages(conversation_id, user_id, opts \\ []) do
    with {:ok, _conversation} <- authorize_conversation(conversation_id, user_id) do
      limit = Keyword.get(opts, :limit, 100)
      offset = Keyword.get(opts, :offset, 0)

      messages =
        Message
        |> where([m], m.conversation_id == ^conversation_id)
        |> order_by([m], asc: m.position)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()

      {:ok, messages}
    end
  end

  def get_conversation_tree(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      # Find root
      root = find_root(conversation)

      # Get all descendants
      descendants =
        Conversation
        |> where([c], c.parent_conversation_id == ^root.id)
        |> Repo.all()

      {:ok, [root | descendants]}
    end
  end

  def replay_conversation(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      {state, _version} = Loader.load(ConversationAggregate, conversation.stream_id)
      {:ok, state}
    end
  end

  def replay_from(conversation_id, user_id, from_version) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      events = Store.read_stream_forward(conversation.stream_id, from_version, 10_000)

      state =
        Enum.reduce(events, ConversationAggregate.init(), fn event, acc ->
          ConversationAggregate.apply_event(acc, event)
        end)

      {:ok, state}
    end
  end

  # --- Internal Helpers ---

  defp authorize_conversation(conversation_id, user_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        if has_access?(conv, user_id) do
          {:ok, conv}
        else
          {:error, :not_found}
        end
    end
  end

  defp authorize_owner(conversation_id, user_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        if conv.user_id == user_id do
          {:ok, conv}
        else
          {:error, :forbidden}
        end
    end
  end

  defp has_access?(conversation, user_id) do
    conversation.user_id == user_id or
      Repo.exists?(
        from a in ConversationAcl,
          where: a.conversation_id == ^conversation.id and a.user_id == ^user_id
      ) or
      Repo.exists?(
        from a in ConversationAcl,
          join: gm in GroupMembership,
          on: gm.group_id == a.group_id and gm.user_id == ^user_id,
          where: a.conversation_id == ^conversation.id and not is_nil(a.group_id)
      )
  end

  defp default_model_id do
    Application.get_env(:liteskill, Liteskill.LLM, [])
    |> Keyword.get(:bedrock_model_id, "us.anthropic.claude-3-5-sonnet-20241022-v2:0")
  end

  defp find_version_at_position(events, position) do
    events
    |> Enum.reduce_while({0, 0}, fn event, {count, version} ->
      case event.event_type do
        type when type in ["UserMessageAdded", "AssistantStreamCompleted"] ->
          new_count = count + 1

          if new_count >= position do
            {:halt, {new_count, event.stream_version}}
          else
            {:cont, {new_count, event.stream_version}}
          end

        _ ->
          {:cont, {count, version}}
      end
    end)
    |> elem(1)
  end

  defp find_root(conversation), do: find_root(conversation, 0)

  # coveralls-ignore-start
  defp find_root(conversation, depth) when depth >= 100, do: conversation
  # coveralls-ignore-stop

  defp find_root(conversation, depth) do
    case conversation.parent_conversation_id do
      nil -> conversation
      parent_id -> find_root(Repo.get!(Conversation, parent_id), depth + 1)
    end
  end

  defp remap_event_data(%{event_type: "ConversationCreated", data: data}, new_conv_id, id_map) do
    {Map.put(data, "conversation_id", new_conv_id), id_map}
  end

  defp remap_event_data(%{event_type: type, data: data}, _new_conv_id, id_map)
       when type in ["UserMessageAdded", "AssistantStreamStarted"] do
    old_id = data["message_id"]
    new_id = Ecto.UUID.generate()
    {Map.put(data, "message_id", new_id), Map.put(id_map, old_id, new_id)}
  end

  # coveralls-ignore-start - only exercised when forking conversations with assistant streaming events
  defp remap_event_data(%{event_type: type, data: data}, _new_conv_id, id_map)
       when type in [
              "AssistantChunkReceived",
              "AssistantStreamCompleted",
              "AssistantStreamFailed",
              "ToolCallStarted",
              "ToolCallCompleted"
            ] do
    new_msg_id = Map.get(id_map, data["message_id"], data["message_id"])
    {Map.put(data, "message_id", new_msg_id), id_map}
  end

  defp remap_event_data(%{data: data}, _new_conv_id, id_map) do
    {data, id_map}
  end

  # coveralls-ignore-stop
end
