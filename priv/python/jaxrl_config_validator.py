"""Validates jaxrl training configs for the dashboard (see validator_server.py).

Importing jaxrl's config models pulls in JAX, which takes about a second, so
the dashboard keeps this running.
"""

import json

import validator_server  # noqa: I001  (first: it guards stdout)
from pydantic import ValidationError

from mapox_trainer.config import Config
from mapox_trainer.envs import create_env_factory

# env_type -> the Pydantic model EnvironmentFactory validates that env with.
# (_registry is private to mapox; there's no public accessor.)
ENV_MODELS = {name: model for name, (_fn, model) in create_env_factory()._registry.items()}


def schema():
    return {
        "config": validator_server.with_order(Config.model_json_schema()),
        "environments": {
            name: validator_server.with_order(model.model_json_schema())
            for name, model in sorted(ENV_MODELS.items())
        },
    }


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
        errors += validator_server.collect_errors(error, env, path)

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
        errors += validator_server.collect_errors(error, config, [])

    if isinstance(config, dict) and isinstance(config.get("environment"), dict):
        errors += validate_env(config["environment"], ["environment"])
    return errors


def format_config(config):
    return Config.model_validate_json(json.dumps(config), strict=True).model_dump_json(indent=2)


if __name__ == "__main__":
    validator_server.serve(schema, validate, format_config)
