from __future__ import annotations

import pytest
from pydantic import ValidationError

from strangertalks_ai.contracts.common import EmptyCapabilityPayload


def test_boundary_payload_is_strictly_empty() -> None:
    assert EmptyCapabilityPayload.model_validate({}).model_dump() == {}

    with pytest.raises(ValidationError):
        EmptyCapabilityPayload.model_validate({"prompt": "not allowed"})
