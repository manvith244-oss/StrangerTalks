defmodule StrangertalksNew.AgentSystemsFakeProviderTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.AgentSystemsFakeProvider, as: FakeProvider

  setup do
    FakeProvider.reset()
    on_exit(&FakeProvider.reset/0)
    :ok
  end

  test "returns explicitly scripted structured output and records the provider boundary call" do
    output = %{"result" => "scripted"}
    schema = %{type: "object"}
    opts = [max_output_tokens: 123]

    assert :ok = FakeProvider.script("safety_review_assistant", {:ok, output})

    assert {:ok, ^output} =
             FakeProvider.structured(
               "safety_review_assistant",
               %{category: "HARASSMENT"},
               "Return JSON.",
               schema,
               opts
             )

    assert [request] = FakeProvider.requests()
    assert request.agent_id == "safety_review_assistant"
    assert request.payload == %{category: "HARASSMENT"}
    assert request.instructions == "Return JSON."
    assert request.schema == schema
    assert request.opts == opts
  end

  test "returns a scripted provider error without reinterpreting it" do
    assert :ok = FakeProvider.script("trend_bridge_research", {:error, :agent_unavailable})

    assert {:error, :agent_unavailable} =
             FakeProvider.structured(
               "trend_bridge_research",
               %{language: "en", signals: ["signal"]},
               "Return JSON.",
               %{type: "object"},
               []
             )
  end
end
