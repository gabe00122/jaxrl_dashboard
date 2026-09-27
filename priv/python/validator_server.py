"""The dashboard's config validator protocol, shared by each project's script.

A project's script (e.g. jaxrl_config_validator.py) runs with that project's
Python, so it imports the real Pydantic models, and is kept running by
JaxrlDashboard.Configs.PythonValidator.

Frames on stdin/stdout are a 4-byte big-endian length followed by UTF-8 JSON.

    {"cmd": "schema"}
      -> {"ok": true, "config": <Config schema>, "environments": {env_type: <schema>}}
    {"cmd": "validate", "config": {...}}
      -> {"ok": true, "errors": [{"loc": ["learner", "model", "num_layers"], "msg": "..."}]}
    {"cmd": "format", "config": {...}}
      -> {"ok": true, "json": "<config as the project would write it>"}  (config must be valid)

"environments" is for projects whose Config leaves the environment open and
validates it against a registry (jaxrl); it's {} otherwise.

Every JSON schema object gets an "x-order" list of its property names, since
JSON objects don't keep key order once decoded on the Elixir side.

Import this module before the project's models: it points sys.stdout at
stderr, so whatever they print while importing can't corrupt the frames.
"""

import json
import os
import struct
import sys
import traceback

os.environ.setdefault("JAX_PLATFORMS", "cpu")

# stdout carries protocol frames only; anything printed while importing the
# project goes to stderr instead.
_frames_out = os.fdopen(os.dup(sys.stdout.fileno()), "wb")
sys.stdout = sys.stderr


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


def unique(errors):
    out = []
    for error in errors:
        if error not in out:
            out.append(error)
    return out


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


def serve(schema, validate, format_config):
    """Answers requests until stdin closes.

    schema() -> {"config": ..., "environments": ...}
    validate(config) -> [{"loc": [...], "msg": "..."}]
    format_config(config) -> str
    """

    def handle(request):
        cmd = request.get("cmd")
        if cmd == "schema":
            return {"ok": True, **schema()}
        if cmd == "validate":
            return {"ok": True, "errors": unique(validate(request["config"]))}
        if cmd == "format":
            return {"ok": True, "json": format_config(request["config"])}
        return {"ok": False, "error": f"unknown command {cmd!r}"}

    stdin = sys.stdin.buffer
    while (request := read_frame(stdin)) is not None:
        try:
            response = handle(request)
        except Exception:
            response = {"ok": False, "error": traceback.format_exc()}
        write_frame(response)
