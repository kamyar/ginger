# Ginger

A small macOS menu bar app that runs your scripts and displays their text output.

**Ginger is a generic script runner.** It has no built-in Codex or weather logic. Widgets are ordinary executable files under `~/.ginger/widgets`. You can add, edit, or remove a widget without changing or rebuilding Ginger. No plugin framework or SDK is required.

The app requires macOS 13 or later. Building requires Xcode and Swift 5.9 or later. A widget can use any language whose interpreter is installed on your Mac.

## Build and run

```sh
./scripts/build-app.sh
open build/Ginger.app
```

On the first launch, Ginger creates an empty configuration and widget directory:

```text
~/.ginger/
  config.json
  widgets/
```

The app does not install widgets automatically. Optional standalone examples are in [`examples/`](examples/README.md). They are not compiled into the app or included in its bundle.

## Add a widget

Create `~/.ginger/widgets/clock` with this content:

```sh
#!/bin/sh
date '+%H:%M'
```

Make the script executable:

```sh
chmod +x ~/.ginger/widgets/clock
```

Select **Reload scripts and configuration** in Ginger's menu. Ginger discovers executable files and adds their settings to `config.json`. New widgets start enabled.

The script can also run without Ginger:

```sh
~/.ginger/widgets/clock
```

### Script output

- The first non-empty stdout line is the menu bar text.
- Output lines appear as separate short rows in the widget menu. Long rows have full-text tooltips.
- Ginger displays up to eight text rows. Additional output remains available in the **More output…** tooltip.
- HTTP and HTTPS links in the output get menu actions. Ginger does not open them automatically.
- A nonzero exit status reports an error. Write the error message to stderr.

Keep output short. Ginger limits the menu bar title to 80 characters and menu text rows to 64 characters. It reads at most 8 KiB of output. On an error, Ginger keeps the last successful output and adds a warning.

Each execution has a 20-second timeout. Ginger does not run the same widget twice at the same time. Use a shebang, the first script line, to select an interpreter. Use `exec` when a shell script only starts another program.

Scripts run with your user permissions. **Install only scripts you trust.** Ginger does not use an App Sandbox.

### Script environment

The working directory is the configuration directory, normally `~/.ginger`. Ginger passes each widget's configured environment variables to its process. It also provides `GINGER_HOME` as an optional convenience for scripts that need the configuration directory.

Scripts do not need to use `GINGER_HOME`. They do not call Ginger or need its executable path. Ginger adds common Homebrew and user executable directories to `PATH`. A widget can override `PATH` in its variables.

## Configuration

```json
{
  "widgets": [
    {
      "id": "clock",
      "name": "Clock",
      "enabled": true,
      "displaySeconds": 10,
      "refreshSeconds": 60,
      "environment": {}
    }
  ]
}
```

`id` is the script filename. The minimum interval is one second. The `environment` object can contain any variable names your script uses. Ginger does not interpret widget variables.

Use the menu to enable or disable widgets, set display durations, set refresh intervals, and edit existing variables. Add variable names through `config.json`. Menu changes are saved immediately. After a manual file change, select **Reload scripts and configuration**.

With two or more enabled widgets, Ginger cycles through them in configuration order. With one enabled widget, Ginger keeps it visible. Refresh runs separately from rotation. Disabled widgets do not start new processes. An existing process can finish.

Use **Show now** to select a widget. Use **Refresh now** to refresh all enabled widgets. Missing or non-executable scripts do not run. Ginger keeps their settings. An invalid configuration file is not replaced.

Set `GINGER_HOME` before launch to use another configuration directory.

## Start at login

Select **Start at login** in Ginger's menu to enable automatic startup when you sign in to macOS. Select it again to disable automatic startup. The checkmark shows the current macOS setting. Ginger does not enable automatic startup by default or change an existing login item setting during an update.

If macOS requires approval, select **Approve in System Settings…** in the menu. Allow Ginger in the Login Items panel. Clicking the pending **Start at login** item removes its registration instead.

Keep `Ginger.app` in a permanent location before you enable automatic startup. The setting uses macOS login-item support. It does not add a custom launch agent.

## Lint

Install the development linters:

```sh
brew install ruff swiftlint
```

Run the Python and Swift checks:

```sh
./scripts/lint.sh
```

Ruff checks and formats Python files, including the executable example scripts without `.py` extensions. SwiftLint checks the Swift source and tests. These tools are not runtime dependencies for Ginger or its widgets.

To fix Python formatting and import order:

```sh
ruff check --fix .
ruff format .
```

### Pre-commit hook

After you clone or initialize the Git repository, install its hook:

```sh
./scripts/install-hooks.sh
```

The hook runs `./scripts/lint.sh` before every commit. A failed lint or formatting check blocks the commit. Checks include the working tree, not only staged files. The hook does not change files automatically.

The installer does not replace an existing hook or change `core.hooksPath`. If an existing global hook forwards to repository hooks, it remains active. Other global hook configurations need to forward to the repository hook for it to run.

Run the installer again after you update `.githooks/pre-commit`. If the installed hook differs, the installer asks you to merge it manually.

## Tests

```sh
swift test
python3 -m unittest discover -s examples/tests -v
```

The Swift tests cover the generic app, script execution, configuration, rotation, output links, and login-item controls. The separate Python tests cover the optional example scripts and their installer.
