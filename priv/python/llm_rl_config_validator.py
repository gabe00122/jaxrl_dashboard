"""Validates llm_rl (valm) training configs for the dashboard (see
validator_server.py).

valm's Config is self-contained: the environment is a tagged union like the
loss and optimizers, so there's no registry of environment schemas.
"""

import json

import validator_server  # noqa: I001  (first: it guards stdout)
from pydantic import ValidationError

from valm.config import Config


def schema():
    return {"config": validator_server.with_order(Config.model_json_schema()), "environments": {}}


def validate(config):
    try:
        # The same call valm's load_config makes.
        Config.model_validate_json(json.dumps(config), strict=True)
    except ValidationError as error:
        return validator_server.collect_errors(error, config, [])
    return []


def format_config(config):
    # Not load_config: that would replace seed "random" with a fixed seed.
    return Config.model_validate_json(json.dumps(config), strict=True).model_dump_json(indent=2)


if __name__ == "__main__":
    validator_server.serve(schema, validate, format_config)
