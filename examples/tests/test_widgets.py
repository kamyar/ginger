import base64
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


codex = load("example_codex", ROOT / "examples/widgets/codex")
weather = load("example_weather", ROOT / "examples/widgets/rain")
installer = load("example_installer", ROOT / "scripts/install-examples.py")


def token(expiration=9999999999):
    payload = json.dumps(
        {"exp": expiration, codex.AUTH_CLAIM: {"chatgpt_account_id": "example-account"}}
    ).encode()
    encoded = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    return "header." + encoded + ".signature"


def forecast(rain_at=3, code=61, probability=80, amount=0.4):
    return {
        "current": {"time": 0, "temperature_2m": 12.4},
        "current_units": {"temperature_2m": "°C"},
        "hourly": {
            "time": [hour * 3600 for hour in range(48)],
            "precipitation_probability": [
                probability if hour == rain_at else 0 for hour in range(48)
            ],
            "rain": [amount if hour == rain_at else 0 for hour in range(48)],
            "showers": [0] * 48,
            "weather_code": [code if hour == rain_at else 0 for hour in range(48)],
        },
    }


class CodexTests(unittest.TestCase):
    def test_existing_login_formats(self):
        access = token()
        for data in [
            {"tokens": {"access_token": access, "account_id": "example-account"}},
            {"openai-codex": {"access": access, "accountId": "example-account"}},
            {"access_token": access},
        ]:
            self.assertEqual(codex.credentials(data), (access, "example-account"))
        self.assertEqual(codex.jwt_payload(None), {})

    def test_expired_missing_and_api_key_credentials_are_rejected(self):
        for data in [{"access_token": token(1)}, {"OPENAI_API_KEY": "not-a-real-api-key"}, {}, []]:
            with self.assertRaises(ValueError):
                codex.credentials(data)

    def test_fallback_and_explicit_file_do_not_change_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            first, second = home / ".codex/auth.json", home / ".pi/agent/auth.json"
            first.parent.mkdir()
            second.parent.mkdir(parents=True)
            expired = json.dumps({"tokens": {"access_token": token(1)}})
            valid = json.dumps({"openai-codex": {"access": token()}})
            first.write_text(expired)
            second.write_text(valid)
            self.assertEqual(codex.load_credentials(home=home)[1], "example-account")
            with self.assertRaises(ValueError):
                codex.load_credentials(auth_file=str(first), home=home)
            self.assertEqual(first.read_text(), expired)
            self.assertEqual(second.read_text(), valid)

    def test_remaining_usage_and_missing_data(self):
        data = {
            "rate_limit": {
                "primary_window": {"used_percent": 16, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 37, "limit_window_seconds": 604800},
            }
        }
        self.assertEqual(codex.format_usage(data).splitlines()[0], "Codex 5h 84% · 7d 63%")
        self.assertTrue(
            codex.format_usage(
                {"rate_limit": {"primary_window": {"used_percent": 102}}}
            ).startswith("Codex primary 0%")
        )
        for data in [{}, [], {"rate_limit": {"primary_window": {"used_percent": None}}}]:
            with self.assertRaises(ValueError):
                codex.format_usage(data)

    def test_usage_request_headers(self):
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(b'{"rate_limit":{}}')
        with mock.patch.object(codex.urllib.request, "build_opener", return_value=opener):
            codex.fetch_usage("example-access-token", "example-account")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, codex.USAGE_URL)
        self.assertEqual(request.get_header("Authorization"), "Bearer example-access-token")
        self.assertEqual(request.get_header("Chatgpt-account-id"), "example-account")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 12)

    def test_usage_http_errors_do_not_expose_response_body(self):
        for status, message in [(401, "expired"), (429, "rate limited"), (500, "HTTP 500")]:
            opener = mock.Mock()
            opener.open.side_effect = urllib.error.HTTPError(
                codex.USAGE_URL, status, "Error", {}, io.BytesIO(b"private-response-body")
            )
            with mock.patch.object(codex.urllib.request, "build_opener", return_value=opener):
                with self.assertRaisesRegex(ValueError, message) as error:
                    codex.fetch_usage("example-access-token", "example-account")
                self.assertNotIn("private-response-body", str(error.exception))

    def test_credentials_cannot_redirect_to_another_host_or_http(self):
        handler = codex.ChatGPTRedirects()
        request = urllib.request.Request(codex.USAGE_URL)
        for url in [
            "https://example.org/",
            "http://chatgpt.com/",
            "https://chatgpt.com.example.org/",
        ]:
            with self.assertRaisesRegex(ValueError, "unsafe redirect"):
                handler.redirect_request(request, None, 302, "", {}, url)
        self.assertIsNotNone(handler.redirect_request(request, None, 302, "", {}, codex.USAGE_URL))

    def test_cli_runs_without_a_ginger_executable(self):
        data = {
            "rate_limit": {"primary_window": {"used_percent": 16, "limit_window_seconds": 18000}}
        }
        output = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"CODEX_AUTH_FILE": "example-auth.json"}, clear=True),
            mock.patch("sys.argv", ["codex"]),
            mock.patch.object(
                codex, "load_credentials", return_value=("example-token", "example-account")
            ) as credentials,
            mock.patch.object(codex, "fetch_usage", return_value=data),
            mock.patch.object(codex, "process_resets"),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(codex.main(), 0)
            credentials.assert_called_once_with("example-auth.json")
        self.assertTrue(output.getvalue().startswith("Codex 5h 84%"))


class CodexNotificationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name) / "cache/usage.json"
        self.send_notification = codex.notify_reset
        patch = mock.patch.object(codex, "notify_reset")
        self.notification = patch.start()
        self.addCleanup(patch.stop)

    def usage(self, reset=100, secondary_reset=None, used=90, seconds=18000):
        data = {
            "rate_limit": {
                "primary_window": {
                    "used_percent": used,
                    "reset_at": reset,
                    "limit_window_seconds": seconds,
                }
            }
        }
        if secondary_reset is not None:
            data["rate_limit"]["secondary_window"] = {
                "used_percent": 80,
                "reset_at": secondary_reset,
                "limit_window_seconds": 604800,
            }
        return data

    def check(self, data, now, notify=True, account="example-account"):
        codex.process_resets(data, account, self.state, notify=notify, now=now)

    def test_first_check_is_private_and_does_not_notify(self):
        self.check(self.usage(), now=50)
        self.notification.assert_not_called()
        state = self.state.read_text()
        self.assertNotIn("example-account", state)
        self.assertNotIn("access_token", state)
        self.assertNotIn("used_percent", state)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.parent.stat().st_mode & 0o777, 0o700)

    def test_reset_notifies_once_even_when_usage_has_already_increased(self):
        self.check(self.usage(), now=50)
        self.check(self.usage(reset=18100, used=95), now=150)
        self.notification.assert_called_once_with(["5h"])
        self.check(self.usage(reset=18100, used=96), now=200)
        self.notification.assert_called_once()

    def test_both_windows_reset_in_one_notification(self):
        self.check(self.usage(secondary_reset=100), now=50)
        self.check(self.usage(reset=18100, secondary_reset=604900), now=150)
        self.notification.assert_called_once_with(["5h", "7d"])

    def test_usage_changes_and_future_reset_changes_do_not_notify(self):
        self.check(self.usage(), now=50)
        self.check(self.usage(reset=110, used=0), now=60)
        self.check(self.usage(reset=110, used=50), now=70)
        self.notification.assert_not_called()

    def test_disabled_and_newly_enabled_settings_do_not_notify(self):
        self.check(self.usage(), now=50, notify=False)
        self.check(self.usage(reset=18100), now=150, notify=False)
        self.check(self.usage(reset=36100), now=18200, notify=True)
        self.notification.assert_not_called()
        self.check(self.usage(reset=54100), now=36200)
        self.notification.assert_called_once_with(["5h"])

    def test_account_duration_and_clock_changes_do_not_notify(self):
        self.check(self.usage(), now=50)
        self.check(self.usage(reset=18100), now=150, account="different-example-account")
        self.check(
            self.usage(reset=36100, seconds=3600), now=18200, account="different-example-account"
        )
        self.check(
            self.usage(reset=54100, seconds=3600), now=18100, account="different-example-account"
        )
        self.notification.assert_not_called()

    def test_missing_reset_metadata_does_not_notify(self):
        self.check(self.usage(), now=50)
        data = self.usage(reset=18100)
        del data["rate_limit"]["primary_window"]["reset_at"]
        self.check(data, now=150)
        self.notification.assert_not_called()

    def test_corrupt_cache_starts_a_new_baseline(self):
        self.state.parent.mkdir()
        for previous in ["not JSON", "[]", '{"windows":null}']:
            self.state.write_text(previous)
            self.check(self.usage(reset=18100), now=150)
            self.notification.assert_not_called()
            self.assertIsInstance(json.loads(self.state.read_text()), dict)

    def test_notification_failure_does_not_repeat_or_break_usage(self):
        self.check(self.usage(), now=50)
        self.notification.side_effect = OSError("Example notification failure")
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.check(self.usage(reset=18100), now=150)
            self.check(self.usage(reset=18100), now=200)
        self.notification.assert_called_once()
        self.assertIn("Could not send", error.getvalue())
        self.assertNotIn("Example notification failure", error.getvalue())

    def test_cache_failure_does_not_send_a_notification(self):
        self.check(self.usage(), now=50)
        with (
            mock.patch.object(codex.tempfile, "NamedTemporaryFile", side_effect=PermissionError),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.check(self.usage(reset=18100), now=150)
        self.notification.assert_not_called()
        self.assertEqual(json.loads(self.state.read_text())["checked_at"], 50)

    def test_cli_is_disabled_by_default_and_flags_override_environment(self):
        for environment, arguments, enabled in [
            ({}, [], False),
            ({"CODEX_NOTIFY_ON_RESET": "true"}, [], True),
            ({}, ["--notify-on-reset"], True),
            ({"CODEX_NOTIFY_ON_RESET": "true"}, ["--no-notify-on-reset"], False),
        ]:
            with (
                mock.patch.dict(os.environ, environment, clear=True),
                mock.patch("sys.argv", ["codex", "--state-file", str(self.state)] + arguments),
                mock.patch.object(
                    codex, "load_credentials", return_value=("example-token", "example-account")
                ),
                mock.patch.object(codex, "fetch_usage", return_value=self.usage()),
                mock.patch.object(codex, "process_resets") as process,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(codex.main(), 0)
                self.assertEqual(process.call_args.kwargs["notify"], enabled)

    def test_failed_usage_requests_do_not_change_state(self):
        self.check(self.usage(), now=50)
        before = self.state.read_bytes()
        with (
            mock.patch("sys.argv", ["codex", "--notify-on-reset", "--state-file", str(self.state)]),
            mock.patch.object(
                codex, "load_credentials", return_value=("example-token", "example-account")
            ),
            mock.patch.object(codex, "fetch_usage", side_effect=ValueError("HTTP 403")),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(codex.main(), 1)
        self.assertEqual(self.state.read_bytes(), before)
        self.notification.assert_not_called()

    def test_notification_uses_static_applescript_and_argument_data(self):
        with mock.patch.object(codex.subprocess, "run") as run:
            self.send_notification(["5h", "7d"])
        arguments = run.call_args.args[0]
        self.assertEqual(
            arguments,
            [
                "/usr/bin/osascript",
                "-e",
                codex.NOTIFICATION_SCRIPT,
                "5h and 7d usage window reset.",
            ],
        )
        self.assertTrue(run.call_args.kwargs["check"])


class WeatherTests(unittest.TestCase):
    def test_coordinates_and_threshold(self):
        self.assertEqual(weather.settings("0", "0", "0.5"), (0, 0, 0.5))
        for values in [("", "", "0.5"), ("91", "0", "0.5"), ("nan", "0", "0.5"), ("0", "0", "2")]:
            with self.assertRaises(ValueError):
                weather.settings(*values)

    def test_rain_countdown_current_hour_and_next_day(self):
        self.assertTrue(weather.format_forecast(forecast(), now=0).startswith("3h 🌧️"))
        self.assertTrue(weather.format_forecast(forecast(rain_at=0), now=1800).startswith("Now 🌧️"))
        self.assertTrue(weather.format_forecast(forecast(rain_at=1), now=1800).startswith("30m 🌧️"))
        self.assertTrue(
            weather.format_forecast(forecast(rain_at=27), now=23.5 * 3600).startswith("4h 🌧️")
        )

    def test_next_weather_change_and_condition_groups(self):
        data = forecast(rain_at=40)
        data["hourly"]["weather_code"] = [0, 1] + [2] * 46
        self.assertTrue(weather.format_forecast(data, now=0).startswith("2h 🌤️"))
        data["hourly"]["weather_code"] = [3] * 3 + [0] * 45
        self.assertTrue(weather.format_forecast(data, now=0).startswith("3h ☀️"))
        self.assertTrue(
            weather.format_forecast(forecast(code=73, amount=0), now=0).startswith("3h 🌨️")
        )

    def test_rain_priority_threshold_and_stable_weather(self):
        data = forecast(rain_at=6)
        data["hourly"]["weather_code"][2] = 3
        self.assertTrue(weather.format_forecast(data, now=0).startswith("6h 🌧️"))
        self.assertTrue(weather.format_forecast(data, now=0, threshold=0.9).startswith("2h ☁️"))
        self.assertTrue(
            weather.format_forecast(forecast(probability=40), now=0).startswith("☀️ Stable 24h")
        )
        data = forecast(rain_at=40)
        data["hourly"]["weather_code"] = [73] * 48
        self.assertTrue(weather.format_forecast(data, now=0).startswith("🌨️ Stable 24h"))

    def test_invalid_or_missing_forecasts_are_not_reported_as_stable(self):
        for key, value in [
            ("rain", [0]),
            ("rain", [None] * 48),
            ("rain", [-1] * 48),
            ("weather_code", [999] * 48),
            ("time", [0] * 48),
            ("precipitation_probability", [101] * 48),
        ]:
            data = forecast()
            data["hourly"][key] = value
            with self.assertRaises(ValueError):
                weather.format_forecast(data, now=0)
        for data in [
            {},
            [],
            {"hourly": {key: value[:12] for key, value in forecast()["hourly"].items()}},
        ]:
            with self.assertRaises(ValueError):
                weather.format_forecast(data, now=0)

    def test_forecast_request_uses_utc_and_sends_no_credentials(self):
        with mock.patch.object(
            weather.urllib.request,
            "urlopen",
            return_value=io.BytesIO(json.dumps(forecast()).encode()),
        ) as open_url:
            weather.fetch_forecast(0, 0)
        request = open_url.call_args.args[0]
        url = urllib.parse.urlsplit(request.full_url)
        query = urllib.parse.parse_qs(url.query)
        self.assertEqual(url.scheme, "https")
        self.assertEqual(url.hostname, "api.open-meteo.com")
        self.assertEqual(query["forecast_days"], ["2"])
        self.assertEqual(query["timeformat"], ["unixtime"])
        self.assertEqual(query["timezone"], ["GMT"])
        self.assertEqual(query["current"], ["temperature_2m"])
        self.assertEqual(query["temperature_unit"], ["celsius"])
        self.assertIsNone(request.get_header("Authorization"))

    def test_current_temperature_is_shown_next_to_the_weather_countdown(self):
        output = weather.format_forecast(forecast(), now=0)
        self.assertEqual(output.splitlines()[0], "3h 🌧️ · 12°C")
        self.assertEqual(
            output.splitlines(),
            [
                "3h 🌧️ · 12°C",
                "Rain probability: 80%",
                "Rain threshold: 50%",
            ],
        )
        self.assertTrue(
            weather.format_forecast(forecast(rain_at=40), now=0).startswith("☀️ Stable 24h · 12°C")
        )

    def test_weather_detail_lines_are_short_and_do_not_repeat_temperature(self):
        for data in [forecast(), forecast(rain_at=40), forecast(code=2, amount=0)]:
            lines = weather.format_forecast(data, now=0).splitlines()
            self.assertTrue(all(len(line) <= 48 for line in lines))
            self.assertEqual(sum("12°C" in line for line in lines), 1)
            self.assertTrue(all("http" not in line for line in lines))
        self.assertEqual(
            weather.format_forecast(forecast(code=2, amount=0), now=0).splitlines()[1],
            "Clear → Partly cloudy",
        )

    def test_weather_has_no_data_row_or_source_link_action(self):
        for data in [forecast(), forecast(rain_at=40), forecast(code=2, amount=0)]:
            output = weather.format_forecast(data, now=0)
            self.assertNotIn("Weather data:", output)
            self.assertNotIn("Open-Meteo", output)
            self.assertNotIn("http", output)

    def test_temperature_rounding_negative_zero_and_fahrenheit(self):
        for value, unit, expected in [
            (12.5, "°C", "13°C"),
            (-1.5, "°C", "-2°C"),
            (-0.1, "°C", "0°C"),
            (54.3, "°F", "54°F"),
        ]:
            data = forecast()
            data["current"]["temperature_2m"] = value
            data["current_units"]["temperature_2m"] = unit
            self.assertEqual(weather.current_temperature(data), expected)

    def test_missing_or_invalid_temperatures_are_not_displayed(self):
        for value in [None, True, "12", float("nan"), float("inf")]:
            data = forecast()
            data["current"]["temperature_2m"] = value
            with self.assertRaisesRegex(ValueError, "current temperature"):
                weather.format_forecast(data, now=0)
        for key in ["current", "current_units"]:
            data = forecast()
            del data[key]
            with self.assertRaisesRegex(ValueError, "current temperature"):
                weather.format_forecast(data, now=0)
        data = forecast()
        data["current_units"]["temperature_2m"] = "kelvin"
        with self.assertRaises(ValueError):
            weather.current_temperature(data)

    def test_forecast_can_request_fahrenheit(self):
        with mock.patch.object(
            weather.urllib.request,
            "urlopen",
            return_value=io.BytesIO(json.dumps(forecast()).encode()),
        ) as open_url:
            weather.fetch_forecast(0, 0, "fahrenheit")
        query = urllib.parse.parse_qs(
            urllib.parse.urlsplit(open_url.call_args.args[0].full_url).query
        )
        self.assertEqual(query["temperature_unit"], ["fahrenheit"])

    def test_temperature_cli_overrides_the_environment(self):
        data = forecast()
        data["current"]["temperature_2m"] = 54.3
        data["current_units"]["temperature_2m"] = "°F"
        output = io.StringIO()
        with (
            mock.patch.dict(
                os.environ,
                {"LATITUDE": "0", "LONGITUDE": "0", "TEMPERATURE_UNIT": "celsius"},
                clear=True,
            ),
            mock.patch("sys.argv", ["rain", "--temperature-unit", "fahrenheit"]),
            mock.patch.object(weather, "fetch_forecast", return_value=data) as fetch,
            mock.patch.object(weather.time, "time", return_value=0),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(weather.main(), 0)
        fetch.assert_called_once_with(0, 0, "fahrenheit")
        self.assertTrue(output.getvalue().startswith("3h 🌧️ · 54°F"))

    def test_invalid_temperature_unit_is_rejected_before_the_request(self):
        with (
            mock.patch.dict(
                os.environ,
                {"LATITUDE": "0", "LONGITUDE": "0", "TEMPERATURE_UNIT": "kelvin"},
                clear=True,
            ),
            mock.patch("sys.argv", ["rain"]),
            mock.patch.object(weather, "fetch_forecast") as fetch,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(weather.main(), 1)
        fetch.assert_not_called()

    def test_forecast_http_errors(self):
        for status, message in [(429, "rate limited"), (500, "HTTP 500")]:
            error = urllib.error.HTTPError("https://example.org", status, "Error", {}, None)
            with mock.patch.object(weather.urllib.request, "urlopen", side_effect=error):
                with self.assertRaisesRegex(ValueError, message):
                    weather.fetch_forecast(0, 0)

    def test_cli_accepts_current_and_previous_variables_without_ginger(self):
        for variables in [
            {"LATITUDE": "0", "LONGITUDE": "0", "RAIN_THRESHOLD": "0.5"},
            {"GINGER_LATITUDE": "0", "GINGER_LONGITUDE": "0", "GINGER_RAIN_THRESHOLD": "0.5"},
        ]:
            output = io.StringIO()
            with (
                mock.patch.dict(os.environ, variables, clear=True),
                mock.patch("sys.argv", ["rain"]),
                mock.patch.object(weather, "fetch_forecast", return_value=forecast()),
                mock.patch.object(weather.time, "time", return_value=0),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(weather.main(), 0)
            self.assertTrue(output.getvalue().startswith("3h 🌧️"))
            self.assertNotIn("http", output.getvalue())


class InstallerTests(unittest.TestCase):
    def test_first_install_uses_optional_example_settings(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            installer.install(directory)
            root = Path(directory)
            config = json.loads((root / "config.json").read_text())
            self.assertEqual([widget["id"] for widget in config["widgets"]], ["codex", "rain"])
            self.assertFalse(config["widgets"][1]["enabled"])
            self.assertTrue(os.access(root / "widgets/rain", os.X_OK))

    def test_user_scripts_and_configuration_are_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            (root / "widgets").mkdir()
            custom = "#!/bin/sh\necho Custom\n"
            (root / "widgets/codex").write_text(custom)
            config = json.dumps(
                {
                    "widgets": [
                        {"id": "codex", "name": "Custom"},
                        {
                            "id": "rain",
                            "enabled": True,
                            "environment": {"GINGER_LATITUDE": "0", "GINGER_LONGITUDE": "0"},
                        },
                    ]
                }
            )
            (root / "config.json").write_text(config)
            installer.install(root, replace_legacy=True)
            self.assertEqual((root / "widgets/codex").read_text(), custom)
            self.assertEqual((root / "config.json").read_text(), config)

    def test_legacy_wrappers_require_explicit_replacement(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            (root / "widgets").mkdir()
            legacy = '#!/bin/sh\nexec "$GINGER_EXECUTABLE" --codex\n'
            (root / "widgets/codex").write_text(legacy)
            installer.install(root)
            self.assertEqual((root / "widgets/codex").read_text(), legacy)
            installer.install(root, replace_legacy=True)
            self.assertEqual(
                (root / "widgets/codex").read_bytes(),
                (ROOT / "examples/widgets/codex").read_bytes(),
            )

    def test_invalid_configuration_is_not_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config.json").write_text("not JSON")
            with self.assertRaises(ValueError):
                installer.install(root)
            self.assertEqual((root / "config.json").read_text(), "not JSON")
            self.assertFalse((root / "widgets").exists())


if __name__ == "__main__":
    unittest.main()
