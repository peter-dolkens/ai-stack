#!/usr/bin/env python3
"""Generate litellm config from template, skipping models whose API keys are not set."""

import os
import yaml

TEMPLATE = "/litellm/config.template.yaml"
OUTPUT = "/tmp/generated-config.yaml"

with open(TEMPLATE) as f:
    config = yaml.safe_load(f)

filtered = []
for model in config.get("model_list", []):
    key_ref = model.get("litellm_params", {}).get("api_key", "")
    if key_ref.startswith("os.environ/"):
        env_var = key_ref[len("os.environ/"):]
        if not os.environ.get(env_var):
            print(f"Skipping {model['model_name']} ({env_var} not set)")
            continue
    filtered.append(model)

config["model_list"] = filtered

with open(OUTPUT, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print(f"Generated config with {len(filtered)} model(s)")
