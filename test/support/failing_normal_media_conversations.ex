defmodule StrangertalksNew.TestFailingNormalMediaConversations do
  def get_conversation(_conversation_id) do
    raise "simulated temporary Conversation lookup failure"
  end
end
