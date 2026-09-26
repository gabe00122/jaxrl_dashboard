"""Validates jaxrl training configs for the dashboard.

Runs with the jaxrl project's Python (so it imports the real Pydantic models)
and is kept running by JaxrlDashboard.Configs.PythonValidator: importing the
config models pulls in JAX, which takes about a second.

Frames on stdin/stdout are a 4-byte big-endian length followed by UTF-8 JSON.

    {"cmd": "schema"}
      -> {"ok": true, "config": <Config schema>, "environments": {env_type: <schema>}}
    {"cmd": "validate", "config": {...}}
      -> {"ok": true, "errors": [{"loc": ["learner", "model", "num_layers"], "msg": "..."}]}
    {"cmd": "format", "config": {...}}
      -> {"ok": true, "json": "<config as jaxrl would write it>"}  (config must be valid)

Every JSON schema object gets an "x-order" list of its property names, since
JSON objects don't keep key order once decoded on the Elixir side.
"""

import json
import os
import struct
import sys
import traceback

os.environ.setdefault("JAX_PLATFORMS", "cpu")

# stdout carries protocol frames only; anything printed while importing JAX
# and the environments goes to stderr instead.
_frames_out = os.fdopen(os.dup(sys.stdout.fileno()), "wb")
sys.stdout = sys.stderr

from pydantic import ValidationError  # noqa: E402

from mapox_trainer.config import Config  # noqa: E402
from mapox_trainer.envs import create_env_factory  # noqa: E402

# env_type -> the Pydantic model EnvironmentFactory validates that env with.
# (_registry is private to mapox; there's no public accessor.)
ENV_MODELS = {name: model for name, (_fn, model) in create_env_factory()._registry.items()}


def with_order(schema):
    if isinstance(schema, dict):
        if isinstance(schema.get("properties"), dict):
            schema["x-order"] = list(schema["properties"].keys())
        for value in schema.values():
            with_order(value)
    elif isinstance(schema, list):
        for value in schema:
            with_order(value)
    return schema


def schema():
    return {
        "config": with_order(Config.model_json_schema()),
        "environments": {
            name: with_order(model.model_json_schema()) for name, model in sorted(ENV_MODELS.items())
        },
    }


def normalize_loc(loc, data, error_type):
    """Maps a Pydantic error location onto the config's actual keys.

    Pydantic adds union tags to locations (e.g. "grid_cnn", "int",
    "literal['random']"); those are dropped so the path can be followed
    through the config. A missing field's final key isn't in the data but is
    kept, since that's where the field goes.
    """
    path, current = [], data
    for i, part in enumerate(loc):
        if isinstance(current, dict) and part in current:
            path.append(part)
            current = current[part]
        elif isinstance(current, list) and isinstance(part, int) and 0 <= part < len(current):
            path.append(part)
            current = current[part]
        elif i == len(loc) - 1 and error_type == "missing" and isinstance(current, dict):
            path.append(part)
    return path


def collect_errors(error, data, prefix):
    return [
        {"loc": prefix + normalize_loc(e["loc"], data, e["type"]), "msg": e["msg"]}
        for e in error.errors(include_url=False)
    ]


def nested_envs(value, path):
    """Environment configs nested inside another one (vec.env, multi.envs[i].env)."""
    if isinstance(value, dict):
        if "env_type" in value:
            yield value, path
            return
        for key, item in value.items():
            yield from nested_envs(item, path + [key])
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from nested_envs(item, path + [i])


def validate_env(env, path):
    """Validates an environment config against its registered model, the way
    EnvironmentFactory.create_env does when the run starts."""
    env_type = env.get("env_type")
    model = ENV_MODELS.get(env_type)

    if model is None:
        if not isinstance(env_type, str):
            return []  # a missing env_type is already reported by Config
        known = ", ".join(sorted(ENV_MODELS))
        return [{"loc": path + ["env_type"], "msg": f"Unknown environment type {env_type!r}. Known types: {known}"}]

    errors = []
    try:
        model.model_validate(env)
    except ValidationError as error:
        errors += collect_errors(error, env, path)

    for key, value in env.items():
        for nested, nested_path in nested_envs(value, path + [key]):
            errors += validate_env(nested, nested_path)
    return errors


def validate(config):
    errors = []
    try:
        # The same call jaxrl's load_config makes.
        Config.model_validate_json(json.dumps(config), strict=True)
    except ValidationError as error:
        errors += collect_errors(error, config, [])

    if isinstance(config, dict) and isinstance(config.get("environment"), dict):
        errors += validate_env(config["environment"], ["environment"])

    unique = []
    for error in errors:
        if error not in unique:
            unique.append(error)
    return unique


def format_config(config):
    return Config.model_validate_json(json.dumps(config), strict=True).model_dump_json(indent=2)


def handle(request):
    cmd = request.get("cmd")
    if cmd == "schema":
        return {"ok": True, **schema()}
    if cmd == "validate":
        return {"ok": True, "errors": validate(request["config"])}
    if cmd == "format":
        return {"ok": True, "json": format_config(request["config"])}
    return {"ok": False, "error": f"unknown command {cmd!r}"}


def read_frame(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    return json.loads(stream.read(length))


def write_frame(message):
    data = json.dumps(message).encode()
    _frames_out.write(struct.pack(">I", len(data)) + data)
    _frames_out.flush()


def main():
    stdin = sys.stdin.buffer
    while (request := read_frame(stdin)) is not None:
        try:
            response = handle(request)
        except Exception:
            response = {"ok": False, "error": traceback.format_exc()}
        write_frame(response)


if __name__ == "__main__":
    main()
