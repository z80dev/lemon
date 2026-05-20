#!/usr/bin/env python3
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

from openai import OpenAI


def main():
    root_url = required_env("LEMON_OPENAI_COMPAT_BASE_URL").rstrip("/")
    base_url = root_url if root_url.endswith("/v1") else f"{root_url}/v1"
    api_key = required_env("LEMON_OPENAI_COMPAT_API_TOKEN")
    model = os.environ.get("LEMON_OPENAI_COMPAT_MODEL", "zai:glm-5-turbo")
    previous_response_id = os.environ.get(
        "LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID", "resp_run_stored_smoke"
    )
    client = OpenAI(api_key=api_key, base_url=base_url)
    checks = []

    check(
        checks,
        "model_retrieve",
        lambda: check_model_retrieve(client),
    )

    check(
        checks,
        "chat_completions_wait",
        lambda: check_chat_completions_wait(client, model),
    )

    check(
        checks,
        "chat_completions_stream",
        lambda: check_chat_completions_stream(client, model),
    )

    check(
        checks,
        "responses_continuation",
        lambda: check_responses_continuation(client, model, previous_response_id),
    )

    check(
        checks,
        "responses_stream",
        lambda: check_responses_stream(client, model),
    )

    check(
        checks,
        "responses_retrieve",
        lambda: check_responses_retrieve(client, previous_response_id),
    )

    proof = {
        "object": "lemon.openai_compat.python_sdk_client_smoke",
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "sdk": "openai-python",
        "endpoint_count": len(checks),
        "completed_count": sum(1 for item in checks if item["status"] == "completed"),
        "failed_count": sum(1 for item in checks if item["status"] == "failed"),
        "results": checks,
        "cleanup": {
            "includes_raw_api_keys": False,
            "includes_raw_prompts": False,
            "includes_raw_answers": False,
            "includes_raw_events": False,
        },
    }

    print(json.dumps(proof, indent=2))
    return 1 if proof["failed_count"] > 0 else 0


def check_model_retrieve(client):
    models = as_dict(client.models.list())
    first = (models.get("data") or [{}])[0]

    if not first.get("id"):
        raise AssertionError("model list returned no id")

    model_object = as_dict(client.models.retrieve(first["id"]))
    require_value(model_object.get("object"), "model", "model.object")
    require_value(model_object.get("id"), first["id"], "model.id")
    require_boolean(
        first.get("lemon", {}).get("supportsVision"),
        "model.list.lemon.supportsVision",
    )
    require_boolean(
        model_object.get("lemon", {}).get("supportsVision"),
        "model.retrieve.lemon.supportsVision",
    )
    require_value(
        model_object["lemon"]["supportsVision"],
        first["lemon"]["supportsVision"],
        "model.supportsVision consistency",
    )
    return {
        "model_id_hash": hash_value(first["id"]),
        "supports_vision": model_object["lemon"]["supportsVision"],
    }


def check_chat_completions_wait(client, model):
    response = as_dict(
        client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": "python sdk client hello"}],
            extra_body={"wait": True, "timeout_ms": 1000},
        )
    )

    require_value(
        response.get("choices", [{}])[0].get("finish_reason"),
        "stop",
        "finish_reason",
    )
    require_value(response.get("lemon", {}).get("status"), "completed", "lemon.status")
    return {
        "answer_hash": hash_value(
            response.get("choices", [{}])[0].get("message", {}).get("content", "")
        )
    }


def check_chat_completions_stream(client, model):
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "python sdk client stream"}],
        stream=True,
    )

    text = ""
    chunk_count = 0

    for chunk in stream:
        chunk_count += 1
        value = as_dict(chunk)
        choices = value.get("choices") or []

        if choices:
            text += choices[0].get("delta", {}).get("content") or ""

    if "stream hello" not in text:
        raise AssertionError("missing streamed delta")

    return {"chunk_count": chunk_count, "text_hash": hash_value(text)}


def check_responses_continuation(client, model, previous_response_id):
    response = as_dict(
        client.responses.create(
            model=model,
            input="python sdk client continue",
            previous_response_id=previous_response_id,
        )
    )

    require_value(
        response.get("previous_response_id"),
        previous_response_id,
        "previous_response_id",
    )
    require_value(
        response.get("lemon", {}).get("previousResponseId"),
        previous_response_id,
        "lemon.previousResponseId",
    )


def check_responses_stream(client, model):
    stream = client.responses.create(
        model=model,
        input="python sdk client response stream",
        stream=True,
    )

    text = ""
    event_count = 0

    for event in stream:
        event_count += 1
        value = as_dict(event)

        if value.get("type") == "response.output_text.delta":
            text += value.get("delta") or ""

    if "stream hello" not in text:
        raise AssertionError("missing streamed response delta")

    return {"event_count": event_count, "text_hash": hash_value(text)}


def check_responses_retrieve(client, previous_response_id):
    response = as_dict(client.responses.retrieve(previous_response_id))
    require_value(response.get("status"), "completed", "stored.status")
    return {"output_hash": hash_value(json.dumps(response.get("output") or []))}


def check(checks, name, fn):
    try:
        extra = fn() or {}
        checks.append({"name": name, "status": "completed", **extra})
    except Exception as error:
        checks.append({"name": name, "status": "failed", "reason": str(error)})


def as_dict(value):
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    if isinstance(value, dict):
        return value
    raise TypeError(f"unsupported response object: {type(value).__name__}")


def require_value(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def require_boolean(actual, label):
    if not isinstance(actual, bool):
        raise AssertionError(f"{label}: expected bool, got {actual!r}")


def hash_value(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:16]


def required_env(name):
    value = os.environ.get(name)

    if not value:
        raise RuntimeError(f"{name} is required")

    return value


if __name__ == "__main__":
    sys.exit(main())
