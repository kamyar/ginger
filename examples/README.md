# Standalone example widgets

These scripts are separate from Ginger. They use Python 3.9 or later and its standard library. No Python packages or Ginger APIs are required.

Each script can run directly in a terminal. You can copy a script to any directory, change it, or use it with another script runner.

## Install in Ginger

```sh
python3 scripts/install-examples.py
```

The installer copies `codex` and `rain` to `~/.ginger/widgets`. It adds settings only when they do not exist. It does not replace user scripts or existing widget settings. New weather examples start disabled until you set coordinates.

Select **Reload scripts and configuration** in Ginger after installation.

### Update from the previous built-in widgets

```sh
python3 scripts/install-examples.py --replace-legacy-wrappers
```

This replaces only the unchanged shell wrappers that called Ginger's old `--codex` and `--rain` commands. Custom scripts are not replaced. Existing coordinates and settings are kept. The new scripts accept the previous `GINGER_*` variable names for compatibility.

## Codex usage

Run the script directly:

```sh
examples/widgets/codex
```

Or select a login file:

```sh
examples/widgets/codex --auth-file /path/to/auth.json
```

The script makes a direct HTTPS request to `https://chatgpt.com/backend-api/codex/usage`. It verifies TLS certificates. It sends the existing access token and account ID only to ChatGPT. It does not call Ginger, Pi, or `/limit`.

By default, it checks `~/.codex/auth.json` and then the optional compatible file `~/.pi/agent/auth.json`. Set `CODEX_AUTH_FILE` to select a file. Leave it empty for automatic detection. The older `GINGER_CODEX_AUTH_FILE` variable also works.

The script reads credentials on each execution. It does not modify, copy, or refresh them. If they expire, sign in again with the tool that created the login file. An OpenAI API key cannot report ChatGPT subscription usage.

Example output:

```text
Codex 5h 84% · 7d 63%
```

Percentages show remaining usage. Reset times appear in the additional output lines. The ChatGPT endpoint is not a documented public API and can change.

## Weather changes

Run the script directly:

```sh
examples/widgets/rain --latitude 0 --longitude 0
```

The coordinates above are an example, not a saved location.

For use in Ginger, set these variables in the widget's configuration or through **Weather → Edit variables**:

- `LATITUDE`: latitude from -90 to 90.
- `LONGITUDE`: longitude from -180 to 180.
- `RAIN_THRESHOLD`: rain probability greater than 0 and no greater than 1. The default is `0.5`.

The previous `GINGER_LATITUDE`, `GINGER_LONGITUDE`, and `GINGER_RAIN_THRESHOLD` names also work. CLI arguments override environment variables. Enable the widget after you set its location. The default refresh interval is 15 minutes.

The script sends the coordinates to [Open-Meteo](https://open-meteo.com/). It verifies TLS certificates and does not send login credentials. No API key or Apple Developer membership is required. The public API is free for personal, non-commercial use within its [usage limits](https://open-meteo.com/en/terms). Commercial use requires a paid plan.

The script checks the next 24 hours. Rain has priority when its probability meets the threshold. Otherwise, it shows the next weather change:

```text
3h 🌧️
11h 🌤️
```

If no qualifying change appears, it shows the current condition with `Stable 24h`. Condition groups include clear, partly cloudy, cloudy, fog, rain, snow, and thunderstorms. Rain below the probability threshold does not trigger a change.

These are hourly estimates, not guarantees or exact start times. Attribution appears in the script output. Ginger handles its link in the same way as links from any other widget.
