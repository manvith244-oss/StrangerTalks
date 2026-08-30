from __future__ import annotations

from strangertalks_ai.providers import protocol


def test_openai_factory_forces_zero_retries_explicit_timeout_and_reused_client(monkeypatch):
    captured = {}
    sentinel_http_client = object()

    class FakeAsyncOpenAI:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(protocol, "AsyncOpenAI", FakeAsyncOpenAI)
    client = protocol.create_openai_client(
        api_key="provider-secret",
        http_client=sentinel_http_client,
        timeout_seconds=7.5,
    )

    assert isinstance(client, FakeAsyncOpenAI)
    assert captured["max_retries"] == 0
    assert captured["timeout"] == 7.5
    assert captured["http_client"] is sentinel_http_client
    assert protocol.OPENAI_STORE is False
