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

### Reset notifications

Set `CODEX_NOTIFY_ON_RESET` to `true` in **Codex → Edit variables** to enable macOS notifications. The default is `false`. For an existing installation, add this variable to the Codex widget's `environment` object in `config.json`. Select **Reload scripts and configuration** after you add it.

The standalone script also accepts this option:

```sh
examples/widgets/codex --notify-on-reset
```

Use `--no-notify-on-reset` to override an enabled environment setting.

The first successful check after you enable notifications establishes a baseline. On later successful checks, the script compares the reset timestamps for each usage window. If a reset occurred between checks, it sends one notification. If both windows reset, it combines them in one notification. It does not send a notification for ordinary usage changes or an account change.

Notifications arrive on the next successful refresh, not at the exact reset time. Failed requests do not update the baseline. Repeated checks do not repeat a notification for the same reset. If ChatGPT returns HTTP 403, reset detection cannot run until a request succeeds.

The script saves check timestamps, usage window durations, and an account hash in `~/Library/Caches/codex-usage/usage.json`. It does not save tokens or the raw account ID. Set `CODEX_STATE_FILE` or use `--state-file` to select another file. Keep this file outside your Git repository. Login files are not changed.

The script sends notifications through macOS `osascript`. Allow notifications for Script Editor if macOS asks. Focus settings can suppress banners. A notification or cache failure does not stop the usage display.

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
- `TEMPERATURE_UNIT`: `celsius` by default, or `fahrenheit`. The `--temperature-unit` CLI option overrides it.

The previous `GINGER_LATITUDE`, `GINGER_LONGITUDE`, and `GINGER_RAIN_THRESHOLD` names also work. CLI arguments override environment variables. Enable the widget after you set its location. The default refresh interval is 15 minutes.

The script uses the coordinates you configure. It does not detect your device location or use IP-based location lookup. Coordinates stay in your local `~/.ginger/config.json`, outside the source repository. They must be updated manually if you move to another location.

The script sends the coordinates to [Open-Meteo](https://open-meteo.com/). It verifies TLS certificates and does not send login credentials. No API key or Apple Developer membership is required. The public API is free for personal, non-commercial use within its [usage limits](https://open-meteo.com/en/terms). Commercial use requires a paid plan.

The script shows the current outdoor temperature estimate next to the countdown. It requests Open-Meteo's current air temperature at two metres above ground. This is a weather model estimate for your configured location, not a reading from your Mac or an outdoor sensor.

The script checks the next 24 hours. Rain has priority when its probability meets the threshold. Otherwise, it shows the next weather change:

```text
3h 🌧️ · 12°C
11h 🌤️ · 15°C
```

The temperature is current. The countdown and icon refer to the next qualifying weather change. The script rounds the temperature to the nearest degree. Missing or invalid temperature data reports an error instead of showing a false reading.

If no qualifying change appears, it shows the current condition with `Stable 24h`. Condition groups include clear, partly cloudy, cloudy, fog, rain, snow, and thunderstorms. Rain below the probability threshold does not trigger a change.

These are hourly estimates, not guarantees or exact start times. Open-Meteo provides the weather data. The provider link is in this documentation, not in the widget menu.
