#!/usr/bin/env python3
"""Print the `run:` script of a composite-action step (selected by id) to stdout."""
import sys

import yaml


def main() -> int:
    action_file, step_id = sys.argv[1], sys.argv[2]
    with open(action_file) as f:
        doc = yaml.safe_load(f)
    for step in doc["runs"]["steps"]:
        if step.get("id") == step_id:
            sys.stdout.write(step["run"])
            return 0
    print(f"step id '{step_id}' not found in {action_file}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
