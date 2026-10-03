#!/usr/bin/env python3
"""Install optional example scripts without replacing user scripts or settings."""

import argparse
import json
import sys
import tempfile
from pathlib import Path

EXAMPLES = Path(__file__).resolve().parent.parent / "examples"


def install(directory, replace_legacy=False):
    directory = Path(directory).expanduser()
    config_file = directory / "config.json"
    config = json.loads(config_file.read_text()) if config_file.exists() else {"widgets": []}
    if not isinstance(config, dict) or not isinstance(config.get("widgets"), list):
        raise ValueError("The existing config.json is invalid. It was not changed.")
    if any(
        not isinstance(widget, dict) or not isinstance(widget.get("id"), str)
        for widget in config["widgets"]
    ):
        raise ValueError("The existing widget settings are invalid. They were not changed.")
    defaults = json.loads((EXAMPLES / "config.json").read_text())
    widgets = directory / "widgets"
    widgets.mkdir(mode=0o700, parents=True, exist_ok=True)
    known = {widget["id"] for widget in config["widgets"]}
    changed = False
    for widget in defaults["widgets"]:
        name = widget["id"]
        source = (EXAMPLES / "widgets" / name).read_bytes()
        destination = widgets / name
        if destination.is_symlink():
            print("Kept user script:", name)
            continue
        existing = destination.read_bytes() if destination.exists() else None
        legacy = ('#!/bin/sh\nexec "$GINGER_EXECUTABLE" --' + name + "\n").encode()
        if existing is None or (replace_legacy and existing == legacy):
            destination.write_bytes(source)
            destination.chmod(0o700)
            print("Installed example:", name)
        elif existing != source:
            print("Kept user script:", name)
            continue
        if name not in known:
            config["widgets"].append(widget)
            known.add(name)
            changed = True
    if changed or not config_file.exists():
        with tempfile.NamedTemporaryFile(
            mode="w", dir=directory, prefix=".config-examples-", delete=False
        ) as handle:
            temporary = Path(handle.name)
            json.dump(config, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        try:
            temporary.replace(config_file)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default=str(Path.home() / ".ginger"))
    parser.add_argument(
        "--replace-legacy-wrappers",
        action="store_true",
        help="Replace only unchanged wrappers from the previous built-in widgets.",
    )
    args = parser.parse_args()
    try:
        install(args.directory, args.replace_legacy_wrappers)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
