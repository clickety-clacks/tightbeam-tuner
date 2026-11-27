import json
import re
import socket
import tempfile
import urllib.error
import urllib.request
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import compatibility_matrix


class SimulatorSelectionTests(unittest.TestCase):
    def _selection(self, runtime_platform, runtimes=None, devicetypes=None):
        device_payload = {
            "devicetypes": devicetypes or [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                }
            ]
        }
        runtime_payload = {
            "runtimes": runtimes or [
                {
                    "isAvailable": True,
                    "platform": runtime_platform,
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                }
            ]
        }
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix,
                "_checked",
                side_effect=[json.dumps(device_payload), json.dumps(runtime_payload)],
            ),
        ):
            return compatibility_matrix._device_and_runtime("26.0")

    def test_selects_current_simctl_ios_platform_and_version_string(self):
        self.assertEqual(
            self._selection("iOS"),
            (
                [("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "iOS 27.2",
            ),
        )

    def test_keeps_compatibility_with_older_simulator_platform_label(self):
        self.assertEqual(self._selection("iOS Simulator")[0][0][1], "iPhone 17 Pro")

    def test_prefers_generic_runtime_and_newest_compatible_device_type(self):
        selected = self._selection(
            "iOS",
            runtimes=[
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
                },
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                },
            ],
            devicetypes=[
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-11",
                    "name": "iPhone 11",
                    "minRuntimeVersion": 1310720,
                    "minRuntimeVersionString": "20.0.0",
                },
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                },
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    "name": "iPhone Duo",
                    "minRuntimeVersion": 1835008,
                    "minRuntimeVersionString": "27.2.0",
                },
            ],
        )
        self.assertEqual(
            selected,
            (
                [
                    ("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "iPhone Duo"),
                    ("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro"),
                    ("com.apple.CoreSimulator.SimDeviceType.iPhone-11", "iPhone 11"),
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "iOS 27.2",
            ),
        )


    def test_rejects_only_device_specific_runtime_variants(self):
        runtimes = {
            "runtimes": [
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
                }
            ]
        }
        devicetypes = {
            "devicetypes": [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                }
            ]
        }
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix,
                "_checked",
                side_effect=[json.dumps(devicetypes), json.dumps(runtimes)],
            ),
            self.assertRaisesRegex(
                compatibility_matrix.MatrixError,
                "no available iPhone simulator runtime at the Tuner deployment target",
            ),
        ):
            compatibility_matrix._device_and_runtime("26.0")

    def test_includes_device_type_introduced_with_the_selected_runtime_for_simctl_probe(self):
        devicetypes = {
            "devicetypes": [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    "name": "iPhone Duo",
                    "minRuntimeVersion": 1835008,
                    "minRuntimeVersionString": "27.2.0",
                }
            ]
        }
        runtimes = {
            "runtimes": [
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                }
            ]
        }
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix,
                "_checked",
                side_effect=[json.dumps(devicetypes), json.dumps(runtimes)],
            ),
        ):
            selected = compatibility_matrix._device_and_runtime("26.0")

        self.assertEqual(
            selected,
            (
                [("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "iPhone Duo")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "iOS 27.2",
            ),
        )


class LoopbackListenerTests(unittest.TestCase):
    def test_loopback_check_queries_only_the_assigned_port_and_rejects_wildcard(self):
        output = (
            "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
            "python 123 user 4u IPv4 0x1 0t0 TCP 127.0.0.1:19450 (LISTEN)\n"
        )
        with (
            mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/sbin/lsof"),
            mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=mock.Mock(returncode=0, stdout=output),
            ) as run,
        ):
            compatibility_matrix._require_loopback_listener(19450, "fixture")
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/sbin/lsof", "-nP", "-a", "-iTCP:19450", "-sTCP:LISTEN"],
        )
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

        external_output = output + (
            "python 123 user 5u IPv6 0x2 0t0 TCP *:19450 (LISTEN)\n"
        )
        with (
            mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/sbin/lsof"),
            mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=mock.Mock(returncode=0, stdout=external_output),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "not bound exclusively to loopback"),
        ):
            compatibility_matrix._require_loopback_listener(19450, "fixture")

    def test_published_runtime_wildcard_listener_is_recorded_not_rejected(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        fixture.gateway_listener_bindings = {}
        with mock.patch.object(
            compatibility_matrix, "_listener_bindings", return_value={"wildcard"}
        ):
            fixture._record_gateway_listener(4304, 19450, "published Tightbeam gateway")
        self.assertEqual(
            fixture.gateway_listener_report(),
            [{"releaseId": 4304, "observedBindings": ["wildcard"]}],
        )

    def test_command_timeout_is_reported_without_echoing_process_output(self):
        with (
            mock.patch.object(
                compatibility_matrix.subprocess,
                "run",
                side_effect=compatibility_matrix.subprocess.TimeoutExpired("lsof", 30),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "command timed out: lsof"),
        ):
            compatibility_matrix._run(["/usr/sbin/lsof", "-nP"], timeout=30)

    def test_command_timeout_retains_sanitized_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            diagnostic = Path(temporary) / "pi-preflight.log"
            with (
                mock.patch.object(
                    compatibility_matrix.subprocess,
                    "run",
                    side_effect=compatibility_matrix.subprocess.TimeoutExpired(
                        "pi", 180, output="startup failed bearer secret-value\n"
                    ),
                ),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "diagnostic retained as pi-preflight.log"),
            ):
                compatibility_matrix._run(
                    ["pi", "--print"], timeout=180, diagnostic_path=diagnostic,
                    diagnostic_redactions={"secret-value"},
                )

            retained = diagnostic.read_text(encoding="utf-8")
            self.assertIn("startup failed", retained)
            self.assertNotIn("secret-value", retained)


class PiHarnessPreflightTests(unittest.TestCase):
    def test_preflights_the_locked_pi_executable_before_simulator_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / "package-lock.json"
            lock.write_text(json.dumps({
                "packages": {
                    "node_modules/@mariozechner/pi-coding-agent": {"version": "0.73.1"}
                }
            }), encoding="utf-8")
            pi_cli = root / "node_modules" / ".bin" / "pi"
            environment = {"HOME": str(root / "home")}
            diagnostic = root / "pi-version.log"

            with mock.patch.object(
                compatibility_matrix, "_checked", return_value="pi v0.73.1\n"
            ) as checked:
                version = compatibility_matrix._preflight_pi_harness(
                    pi_cli, lock, env=environment, cwd=root, diagnostic_path=diagnostic,
                )

        self.assertEqual(version, "0.73.1")
        self.assertEqual(checked.call_args.args[0], [str(pi_cli), "--version"])
        self.assertEqual(checked.call_args.kwargs["env"], environment)
        self.assertEqual(checked.call_args.kwargs["timeout"], 120)
        self.assertEqual(checked.call_args.kwargs["diagnostic_path"], diagnostic)


    def test_runs_the_locked_pi_against_the_loopback_completion_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_requests = []
            diagnostic = root / "diagnostics" / "pi-preflight.log"
            endpoint = "http://127.0.0.1:19451/v1"

            def run_pi(args, **kwargs):
                model_requests.append({
                    "method": "POST", "path": "/v1/chat/completions", "model": "tuner-fixture",
                })
                return compatibility_matrix.subprocess.CompletedProcess(
                    args, 0, "Tightbeam compatibility fixture reply.\n"
                )

            with mock.patch.object(
                compatibility_matrix.subprocess, "run", side_effect=run_pi
            ) as run:
                result = compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint=endpoint,
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=model_requests,
                    diagnostic_path=diagnostic,
                    diagnostic_redactions={"private-fixture-value"},
                )

            self.assertEqual(result["status"], "passed")
            self.assertTrue(result["requestObserved"])
            self.assertEqual(run.call_args.args[0][1:7], [
                "--model", "tunerci/tuner-fixture", "--print", "--no-session",
                "--no-tools",
                "Reply with a short greeting for the Tuner compatibility fixture.",
            ])
            self.assertEqual(run.call_args.kwargs["timeout"], 180)
            self.assertTrue(diagnostic.is_file())
            configured = json.loads((root / "home/.pi/agent/models.json").read_text(encoding="utf-8"))
            provider = configured["providers"]["tunerci"]
            self.assertEqual(provider["baseUrl"], endpoint)
            self.assertEqual(provider["api"], "openai-completions")
            self.assertEqual(diagnostic.read_text(encoding="utf-8").strip(), "Tightbeam compatibility fixture reply.")

    def test_rejects_preflight_without_a_local_completion_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            diagnostic = root / "pi-preflight.log"
            with (
                mock.patch.object(
                    compatibility_matrix.subprocess,
                    "run",
                    return_value=compatibility_matrix.subprocess.CompletedProcess(
                        ["pi"], 0, "Tightbeam compatibility fixture reply.\n"
                    ),
                ),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "made no request to the local completion endpoint"),
            ):
                compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint="http://127.0.0.1:19451/v1",
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=[],
                    diagnostic_path=diagnostic,
                    diagnostic_redactions=set(),
                )

    def test_rejects_non_loopback_model_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(compatibility_matrix.MatrixError, "endpoint must be the local compatibility model"):
                compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint="https://model.example/v1",
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=[],
                    diagnostic_path=root / "pi-preflight.log",
                    diagnostic_redactions=set(),
                )

    def test_rejects_a_pi_executable_that_disagrees_with_the_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / "package-lock.json"
            lock.write_text(json.dumps({
                "packages": {
                    "node_modules/@mariozechner/pi-coding-agent": {"version": "0.73.1"}
                }
            }), encoding="utf-8")
            with (
                mock.patch.object(compatibility_matrix, "_checked", return_value="pi v0.72.0"),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "locked version"),
            ):
                compatibility_matrix._preflight_pi_harness(
                    root / "pi", lock, env={}, cwd=root
                )


class RuntimeLocalModelConfigurationTests(unittest.TestCase):
    def test_onboards_and_spawns_the_supported_keyless_runtime_model(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        fixture.model_origin = {
            "scheme": "http", "host": "127.0.0.1", "port": 19451, "basePath": "/v1",
        }
        fixture._cli = mock.Mock(return_value="")

        fixture._onboard_runtime_local_model(449379583, "scratch-admin")
        onboard_call = fixture._cli.call_args
        self.assertEqual(onboard_call.args, (
            449379583, "onboard", "local-openai", "--name", "spark",
            "--endpoint", "http://127.0.0.1:19451/v1", "--as-user", "scratch-admin",
        ))
        self.assertEqual(onboard_call.kwargs["timeout"], 300)
        self.assertNotIn("--api-key", onboard_call.args)

        fixture._spawn_runtime_pi_child(449379583, "scratch-admin")
        spawn_call = fixture._cli.call_args
        self.assertEqual(spawn_call.args[:8], (
            449379583, "spawn", "--as-user", "scratch-admin",
            "--display", "Tuner compatibility reply", "--harness", "pi",
        ))
        self.assertEqual(spawn_call.args[8:10], ("--model", "spark/qwen3.5-35b"))
        self.assertEqual(spawn_call.kwargs["timeout"], 300)


class ReplyCorrelationDiagnosticTests(unittest.TestCase):
    def test_snapshot_distinguishes_acknowledged_human_and_matching_assistant_metadata(self):
        session_key = "agent:main:fixture:main"
        client_message_id = "c_fixture_message_id"
        items = [
            {
                "sessionKey": session_key,
                "role": "user",
                "clientMessageId": client_message_id,
                "seq": 4,
            },
            {
                "sessionKey": session_key,
                "role": "assistant",
                "turnIncludesHuman": True,
                "replyToClientMessageId": client_message_id,
                "seq": 5,
            },
            {
                "sessionKey": session_key,
                "role": "assistant",
                "turnIncludesHuman": False,
                "seq": 6,
            },
            {
                "sessionKey": "agent:main:other:main",
                "role": "assistant",
                "turnIncludesHuman": True,
                "replyToClientMessageId": client_message_id,
                "seq": 7,
            },
        ]

        snapshot, reply_sequence = compatibility_matrix._reply_correlation_snapshot(
            items, session_key, client_message_id
        )

        self.assertTrue(snapshot["humanPostPersisted"])
        self.assertEqual(snapshot["humanSequence"], 4)
        self.assertEqual(snapshot["assistantRowsAfterHumanCount"], 2)
        self.assertTrue(snapshot["correlatedReplyFound"])
        self.assertEqual(reply_sequence, 5)
        encoded = json.dumps(snapshot)
        self.assertNotIn(session_key, encoded)
        self.assertNotIn(client_message_id, encoded)

    def test_timeout_retains_human_persistence_reply_lookup_and_post_model_requests(self):
        observation = {"postSubmitted": True, "postAcknowledged": True}
        model_requests = [{
            "method": "POST",
            "releaseId": 449379583,
            "stream": True,
            "responseStatus": 200,
            "responseCompleted": True,
        }]
        page = {"items": [{
            "sessionKey": "agent:main:fixture:main",
            "role": "user",
            "clientMessageId": "fixture-message",
            "seq": 4,
        }]}

        with (
            mock.patch.object(compatibility_matrix, "_http_json", return_value=(200, page)),
            mock.patch.object(compatibility_matrix.time, "monotonic", side_effect=[0.0, 0.0, 0.0, 2.0]),
            mock.patch.object(compatibility_matrix.time, "sleep"),
            self.assertRaisesRegex(
                compatibility_matrix.MatrixError,
                "did not persist a correlated assistant reply",
            ),
        ):
            compatibility_matrix._wait_for_reply(
                "http://127.0.0.1:19450",
                "agent:main:fixture:main",
                "fixture-message",
                timeout=1,
                observation=observation,
                model_requests=model_requests,
            )

        self.assertTrue(observation["postSubmitted"])
        self.assertTrue(observation["postAcknowledged"])
        self.assertEqual(observation["replyLookup"], {"httpStatus": 200, "itemCount": 1})
        self.assertTrue(observation["replyCorrelation"]["humanPostPersisted"])
        self.assertFalse(observation["replyCorrelation"]["correlatedReplyFound"])
        self.assertEqual(observation["modelRequestsAfterHumanPost"]["requestCount"], 1)
        self.assertEqual(observation["modelRequestsAfterHumanPost"]["completedResponseCount"], 1)

    def test_model_request_observation_keeps_response_state_without_payloads(self):
        snapshot = compatibility_matrix._model_request_observations([{
            "method": "POST",
            "path": "/v1/chat/completions",
            "origin": {"scheme": "http", "host": "127.0.0.1", "port": 19450, "basePath": "/v1"},
            "releaseId": 449379583,
            "model": "tuner-fixture",
            "stream": True,
            "responseStatus": 200,
            "responseCompleted": True,
            "elapsedMsAfterHumanPost": 25,
            "body": "must not be retained",
        }])

        self.assertEqual(snapshot["requestCount"], 1)
        self.assertEqual(snapshot["completedResponseCount"], 1)
        self.assertEqual(snapshot["requests"][0]["responseStatus"], 200)
        self.assertEqual(snapshot["requests"][0]["path"], "/v1/chat/completions")
        self.assertEqual(snapshot["requests"][0]["model"], "tuner-fixture")
        self.assertEqual(snapshot["requests"][0]["origin"]["port"], 19450)
        self.assertEqual(snapshot["requests"][0]["elapsedMsAfterHumanPost"], 25)
        self.assertTrue(snapshot["requests"][0]["responseCompleted"])
        self.assertNotIn("body", json.dumps(snapshot))
        self.assertNotIn("must not be retained", json.dumps(snapshot))

    def test_dispatch_frame_summary_keeps_lifecycle_labels_without_ids_or_payload(self):
        summary = compatibility_matrix._dispatch_frame_observation({
            "type": "turn_state",
            "state": "running",
            "status": "started",
            "phase": "dispatch",
            "role": "assistant",
            "seq": 12,
            "turnIncludesHuman": True,
            "id": "fixture-message",
            "replyToClientMessageId": "fixture-message",
            "sessionKey": "private-session-key",
            "content": "private model content",
            "token": "private-secret",
        }, "fixture-message")

        self.assertEqual(summary["frameType"], "turn_state")
        self.assertEqual(summary["state"], "running")
        self.assertEqual(summary["status"], "started")
        self.assertEqual(summary["sequence"], 12)
        self.assertTrue(summary["idMatches"])
        self.assertTrue(summary["replyToClientMessageIdMatches"])
        encoded = json.dumps(summary)
        for private in ("fixture-message", "private-session-key", "private model content", "private-secret"):
            self.assertNotIn(private, encoded)

    def test_wait_for_reply_records_dispatch_lifecycle_through_correlated_persistence(self):
        message_id = "fixture-message"
        page = {"items": [
            {
                "sessionKey": "agent:main:fixture:main",
                "role": "user",
                "clientMessageId": message_id,
                "seq": 4,
            },
            {
                "sessionKey": "agent:main:fixture:main",
                "role": "assistant",
                "turnIncludesHuman": True,
                "replyToClientMessageId": message_id,
                "seq": 5,
            },
        ]}

        class WebSocket:
            def __init__(self):
                self.frames = iter([
                    {
                        "type": "turn_state",
                        "state": "running",
                        "sessionKey": "private-session-key",
                        "id": message_id,
                        "content": "private content",
                    },
                    {
                        "type": "assistant_message",
                        "role": "assistant",
                        "turnIncludesHuman": True,
                        "replyToClientMessageId": message_id,
                        "seq": 5,
                    },
                ])

            def receive_json(self, timeout=15):
                try:
                    return next(self.frames)
                except StopIteration:
                    raise socket.timeout

        observation = {"postSubmitted": True, "postAcknowledged": True, "dispatchLifecycle": []}
        with mock.patch.object(compatibility_matrix, "_http_json", return_value=(200, page)):
            sequence = compatibility_matrix._wait_for_reply(
                "http://127.0.0.1:19450",
                "agent:main:fixture:main",
                message_id,
                timeout=1,
                observation=observation,
                websocket=WebSocket(),
            )

        self.assertEqual(sequence, 5)
        events = observation["dispatchLifecycle"]
        self.assertEqual([item["frameType"] for item in events if item["event"] == "websocket_frame"], [
            "turn_state", "assistant_message",
        ])
        self.assertEqual(events[-1]["event"], "correlated_assistant_persisted")
        self.assertEqual(events[-1]["sequence"], 5)
        encoded = json.dumps(observation)
        self.assertNotIn(message_id, encoded)
        self.assertNotIn("private-session-key", encoded)
        self.assertNotIn("private content", encoded)


class LocalModelStreamingTests(unittest.TestCase):
    def test_gate_probe_runs_through_bash_and_relays_the_observed_tool_result(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            fixture.model_port = reserve.getsockname()[1]
        fixture.model_requests = []
        fixture.selected_release_id = 449379583
        fixture.model_origin = {
            "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
        }
        fixture.active_turn_started_at = None
        fixture.model_server = None
        fixture.model_thread = None
        tools = [{
            "type": "function",
            "function": {
                "name": "bash",
                "parameters": {
                    "type": "object",
                    "properties": {"command": {"type": "string"}},
                    "required": ["command"],
                },
            },
        }]
        prompt = "Use your shell tool to run " + compatibility_matrix.GATE_PROBE_COMMAND

        with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
            fixture._start_model_server()
        try:
            def read_tool_call() -> dict:
                request = urllib.request.Request(
                    f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                    data=json.dumps({
                        "model": "qwen3.5-35b", "stream": True,
                        "messages": [{"role": "system", "content": prompt}], "tools": tools,
                    }).encode("utf-8"),
                    headers={"Content-Type": "application/json"}, method="POST",
                )
                with urllib.request.urlopen(request, timeout=5) as response:
                    events = [item for item in response.read().decode("utf-8").split("\n\n") if item]
                tool_chunks = [
                    json.loads(event.removeprefix("data: "))
                    for event in events if event.startswith("data: ") and event != "data: [DONE]"
                ]
                call = tool_chunks[1]["choices"][0]["delta"]["tool_calls"][0]
                self.assertEqual(tool_chunks[2]["choices"][0]["finish_reason"], "tool_calls")
                return call

            with mock.patch.object(compatibility_matrix.secrets, "token_hex", side_effect=["1" * 32, "2" * 32]):
                tool_call = read_tool_call()
                second_tool_call = read_tool_call()
            self.assertEqual(tool_call["function"]["name"], "bash")
            self.assertRegex(
                tool_call["id"],
                re.escape(compatibility_matrix.GATE_PROBE_TOOL_CALL_PREFIX) + r"[0-9a-f]{32}",
            )
            self.assertNotEqual(tool_call["id"], second_tool_call["id"])
            self.assertEqual(json.loads(tool_call["function"]["arguments"])["command"],
                             compatibility_matrix.GATE_PROBE_COMMAND)

            followup = urllib.request.Request(
                f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                data=json.dumps({
                    "model": "qwen3.5-35b", "stream": False,
                    "messages": [
                        {"role": "system", "content": prompt},
                        {"role": "assistant", "content": None, "tool_calls": [{
                            "id": tool_call["id"], "type": "function", "function": tool_call["function"],
                        }]},
                        {"role": "tool", "tool_call_id": tool_call["id"],
                         "content": {"terminal_output": {
                             "data": compatibility_matrix.GATE_PROBE_MARKER + "\nactual probe output",
                         }}},
                    ], "tools": tools,
                }).encode("utf-8"),
                headers={"Content-Type": "application/json"}, method="POST",
            )
            with urllib.request.urlopen(followup, timeout=5) as response:
                result = json.loads(response.read().decode("utf-8"))
            self.assertEqual(
                result["choices"][0]["message"]["content"],
                compatibility_matrix.GATE_PROBE_MARKER + "\nactual probe output",
            )
        finally:
            fixture.model_server.shutdown()
            fixture.model_server.server_close()
            fixture.model_thread.join(timeout=5)

        observations = compatibility_matrix._model_request_observations(fixture.model_requests)
        self.assertEqual(
            [item["fixtureInteraction"] for item in observations["requests"]],
            ["gate-probe-tool-call", "gate-probe-tool-call", "gate-probe-marker-returned"],
        )
        self.assertNotIn(compatibility_matrix.GATE_PROBE_COMMAND, json.dumps(observations))
        self.assertNotIn(compatibility_matrix.GATE_PROBE_MARKER, json.dumps(observations))

    def test_gate_probe_does_not_retry_when_its_tool_result_is_missing_or_mismatched(self):
        prompt = "Use your shell tool to run " + compatibility_matrix.GATE_PROBE_COMMAND
        call_id = compatibility_matrix.GATE_PROBE_TOOL_CALL_PREFIX + ("0" * 32)
        call = {
            "id": call_id,
            "type": "function",
            "function": {
                "name": "bash",
                "arguments": json.dumps({"command": compatibility_matrix.GATE_PROBE_COMMAND}),
            },
        }
        base = {
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "assistant", "content": None, "tool_calls": [call]},
            ],
            "tools": [],
        }

        with self.assertRaisesRegex(
            compatibility_matrix.MatrixError, "did not receive one correlated runtime shell-tool result",
        ):
            compatibility_matrix._gate_probe_action(base)

        mismatched = {
            **base,
            "messages": [
                *base["messages"],
                {"role": "tool", "tool_call_id": "different-call", "content": "actual refusal"},
            ],
        }
        with self.assertRaisesRegex(
            compatibility_matrix.MatrixError, "did not receive one correlated runtime shell-tool result",
        ):
            compatibility_matrix._gate_probe_action(mismatched)

        with self.assertRaisesRegex(
            compatibility_matrix.MatrixError, "without a compatible bash tool",
        ):
            compatibility_matrix._gate_probe_action({
                "messages": [{"role": "system", "content": prompt}], "tools": [],
            })

    def test_gate_probe_relays_the_failed_tool_update_verbatim(self):
        prompt = "Use your shell tool to run " + compatibility_matrix.GATE_PROBE_COMMAND
        call_id = compatibility_matrix.GATE_PROBE_TOOL_CALL_PREFIX + ("a" * 32)
        call = {
            "id": call_id,
            "type": "function",
            "function": {
                "name": "bash",
                "arguments": json.dumps({"command": compatibility_matrix.GATE_PROBE_COMMAND}),
            },
        }
        refusal = "actual blocked command result"
        result = compatibility_matrix._gate_probe_action({
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "assistant", "content": None, "tool_calls": [call]},
                {"role": "tool", "tool_call_id": call_id,
                 "content": {"terminal_output": {"data": refusal}}},
            ],
        })

        self.assertEqual(result["content"], refusal)
        self.assertFalse(result["observedMarker"])

    def test_runtime_catalog_model_is_discovered_and_served_by_the_loopback_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                fixture.model_port = reserve.getsockname()[1]
            fixture.model_requests = []
            fixture.selected_release_id = 449379583
            fixture.model_origin = {
                "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
            }
            fixture.active_turn_started_at = None
            fixture.model_server = None
            fixture.model_thread = None

            with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
                fixture._start_model_server()
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{fixture.model_port}/v1/models", timeout=5,
                ) as response:
                    models = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                self.assertIn("qwen3.5-35b", {item["id"] for item in models["data"]})

                request = urllib.request.Request(
                    f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                    data=json.dumps({"model": "qwen3.5-35b", "stream": False}).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=5) as response:
                    completion = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                self.assertEqual(completion["model"], "qwen3.5-35b")
            finally:
                fixture.model_server.shutdown()
                fixture.model_server.server_close()
                fixture.model_thread.join(timeout=5)

        self.assertEqual(fixture.model_requests[1]["model"], "qwen3.5-35b")
        observation = compatibility_matrix._model_request_observations(fixture.model_requests)
        self.assertEqual(observation["requests"][1]["model"], "qwen3.5-35b")
        self.assertNotIn("body", json.dumps(observation))

    def test_model_preflight_matches_valid_completion_recorded_by_fixture_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                fixture.model_port = reserve.getsockname()[1]
            fixture.model_requests = []
            fixture.selected_release_id = 449379583
            fixture.model_origin = {
                "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
            }
            fixture.active_turn_started_at = None
            fixture.model_server = None
            fixture.model_thread = None

            with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
                fixture._start_model_server()
            try:
                def run_pi(args, **kwargs):
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                        data=json.dumps({"model": "tuner-fixture", "stream": False}).encode("utf-8"),
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )
                    with urllib.request.urlopen(request, timeout=5) as response:
                        self.assertEqual(response.status, 200)
                        self.assertIn("Tightbeam compatibility fixture reply.", response.read().decode("utf-8"))
                    return compatibility_matrix.subprocess.CompletedProcess(
                        args, 0, "Tightbeam compatibility fixture reply.\n"
                    )

                with mock.patch.object(compatibility_matrix.subprocess, "run", side_effect=run_pi):
                    result = compatibility_matrix._preflight_pi_model(
                        root / "pi",
                        home=root / "home",
                        endpoint=f"http://127.0.0.1:{fixture.model_port}/v1",
                        env={"HOME": str(root / "home")},
                        cwd=root,
                        observed_requests=fixture.model_requests,
                        diagnostic_path=root / "pi-preflight.log",
                        diagnostic_redactions=set(),
                    )
            finally:
                fixture.model_server.shutdown()
                fixture.model_server.server_close()
                fixture.model_thread.join(timeout=5)

        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["requestObserved"])
        self.assertEqual(fixture.model_requests[0]["model"], "tuner-fixture")
        observation = compatibility_matrix._model_request_observations(fixture.model_requests)
        self.assertEqual(observation["requests"][0]["model"], "tuner-fixture")
        self.assertEqual(observation["requests"][0]["responseStatus"], 200)
        self.assertNotIn("body", json.dumps(observation))

    def test_model_server_records_unmatched_methods_and_paths_without_query_or_body(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            fixture.model_port = reserve.getsockname()[1]
        fixture.model_origin = {
            "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
        }
        fixture.model_requests = []
        fixture.selected_release_id = 449379583
        fixture.active_turn_started_at = None
        fixture.model_server = None
        fixture.model_thread = None

        with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
            fixture._start_model_server()
        try:
            with self.assertRaises(urllib.error.HTTPError) as get_error:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{fixture.model_port}/v1/unknown?token=private-query-secret",
                    timeout=5,
                )
            self.assertEqual(get_error.exception.code, 404)

            put = urllib.request.Request(
                f"http://127.0.0.1:{fixture.model_port}/v1/unsupported",
                data=b"private request body",
                method="PUT",
            )
            with self.assertRaises(urllib.error.HTTPError) as put_error:
                urllib.request.urlopen(put, timeout=5)
            self.assertEqual(put_error.exception.code, 501)

            with urllib.request.urlopen(
                f"http://127.0.0.1:{fixture.model_port}/v1/models", timeout=5
            ) as response:
                self.assertEqual(response.status, 200)
        finally:
            fixture.model_server.shutdown()
            fixture.model_server.server_close()
            fixture.model_thread.join(timeout=5)

        observed = compatibility_matrix._model_request_observations(fixture.model_requests)
        self.assertEqual(
            [(item["method"], item["path"], item["responseStatus"]) for item in observed["requests"]],
            [
                ("GET", "/v1/unknown", 404),
                ("PUT", "/v1/unsupported", 501),
                ("GET", "/v1/models", 200),
            ],
        )
        self.assertTrue(all(
            item["origin"] == {
                "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
            }
            for item in observed["requests"]
        ))
        encoded = json.dumps(observed)
        self.assertNotIn("private-query-secret", encoded)
        self.assertNotIn("private request body", encoded)

    def test_streaming_completion_emits_compact_json_sse_data_lines(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            fixture.model_port = reserve.getsockname()[1]
        fixture.model_requests = []
        fixture.selected_release_id = 449379583
        fixture.model_origin = {
            "scheme": "http", "host": "127.0.0.1", "port": fixture.model_port, "basePath": "/v1",
        }
        fixture.active_turn_started_at = None
        fixture.model_server = None
        fixture.model_thread = None

        with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
            fixture._start_model_server()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                data=json.dumps({"model": "tuner-fixture", "stream": True}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(response.headers.get_content_type(), "text/event-stream")
                body = response.read().decode("utf-8")
        finally:
            fixture.model_server.shutdown()
            fixture.model_server.server_close()
            fixture.model_thread.join(timeout=5)

        events = [event for event in body.split("\n\n") if event]
        self.assertEqual(len(events), 4)
        decoded = []
        for event in events[:-1]:
            self.assertTrue(event.startswith("data: "))
            payload = event.removeprefix("data: ")
            self.assertNotIn("\n", payload)
            decoded.append(json.loads(payload))
        self.assertEqual(events[-1], "data: [DONE]")
        self.assertEqual(decoded[0]["choices"][0]["delta"]["role"], "assistant")
        self.assertEqual(decoded[1]["choices"][0]["delta"]["content"], "Tightbeam compatibility fixture reply.")
        self.assertEqual(decoded[2]["choices"][0]["finish_reason"], "stop")
        self.assertEqual(fixture.model_requests, [{
            "method": "POST",
            "path": "/v1/chat/completions",
            "origin": fixture.model_origin,
            "releaseId": 449379583,
            "model": "tuner-fixture",
            "stream": True,
            "responseStatus": 200,
            "responseCompleted": True,
            "elapsedMsAfterHumanPost": None,
        }])


class SimulatorCleanupTests(unittest.TestCase):
    def test_delete_verifies_owned_device_absence_even_if_shutdown_result_is_stale(self):
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 1, "device is already shut down"),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "device already deleted"),
            compatibility_matrix.subprocess.CompletedProcess(
                [], 0, json.dumps({"devices": {"runtime": []}})
            ),
        ]
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
        ):
            compatibility_matrix._delete_simulator("12345678-1234-1234-1234-123456789012")
        self.assertEqual(len(run.call_args_list), 3)
        self.assertEqual(run.call_args_list[-1].args[0][2:], ["list", "devices", "--json"])

    def test_delete_fails_if_owned_device_remains_in_inventory(self):
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, ""),
            compatibility_matrix.subprocess.CompletedProcess([], 0, ""),
            compatibility_matrix.subprocess.CompletedProcess(
                [], 0, json.dumps({"devices": {"runtime": [{"udid": "task-device"}]}})
            ),
        ]
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "retained the compatibility matrix's owned simulator"),
        ):
            compatibility_matrix._delete_simulator("task-device")


class SimulatorBootRetryTests(unittest.TestCase):
    def test_simulator_create_failure_retains_xcrun_output(self):
        create_error = "simctl create failed: selected iOS runtime is unavailable"
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix.subprocess,
                "run",
                return_value=compatibility_matrix.subprocess.CompletedProcess([], 1, create_error),
            ) as subprocess_run,
            self.assertRaisesRegex(
                compatibility_matrix.MatrixError,
                "diagnostic retained as simulator-create.log",
            ),
        ):
            diagnostic_directory = Path(temporary) / "simulator-diagnostics"
            compatibility_matrix._create_simulator(
                [("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=diagnostic_directory,
            )
            self.assertEqual(
                subprocess_run.call_args.args[0][1:3],
                ["simctl", "create"],
            )
            self.assertEqual(
                (diagnostic_directory / "simulator-create.log").read_text(encoding="utf-8"),
                create_error,
            )

    def test_tries_next_device_type_after_simctl_reports_incompatible_pair(self):
        udid = "12345678-1234-1234-1234-123456789012"
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 1, "Incompatible device"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, udid),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "boot complete"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "ready"),
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
        ):
            result = compatibility_matrix._create_simulator(
                [
                    ("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "iPhone Duo"),
                    ("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro"),
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                86,
                diagnostic_directory=Path(temporary) / "simulator-diagnostics",
            )

        self.assertEqual(
            result,
            (
                udid,
                "TunerCompatibility-86",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "iPhone 17 Pro",
            ),
        )
        self.assertEqual(run.call_args_list[0].args[0][4], "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")
        self.assertEqual(run.call_args_list[1].args[0][4], "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        self.assertEqual(run.call_args_list[1].args[0][5], "com.apple.CoreSimulator.SimRuntime.iOS-27-2")

    def test_retries_boot_once_after_bounded_readiness_failure(self):
        udid = "12345678-1234-1234-1234-123456789012"
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, udid),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "first boot failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown complete"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "boot complete"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "ready"),
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
            mock.patch.object(compatibility_matrix.time, "sleep"),
        ):
            result = compatibility_matrix._create_simulator(
                [("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=Path(temporary) / "simulator-diagnostics",
            )

        self.assertEqual(
            result,
            (
                udid,
                "TunerCompatibility-86",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "iPhone 17 Pro",
            ),
        )
        self.assertEqual(run.call_args_list[1].args[0][2:4], ["boot", udid])
        self.assertEqual(run.call_args_list[2].args[0][2:4], ["shutdown", udid])
        self.assertEqual(run.call_args_list[3].args[0][2:4], ["boot", udid])
        self.assertEqual(run.call_args_list[4].args[0][2:5], ["bootstatus", udid, "-b"])
        self.assertEqual(run.call_args_list[1].kwargs["timeout"], 90)
        self.assertEqual(run.call_args_list[4].kwargs["timeout"], 300)

    def test_boot_failure_retains_diagnostics_and_deletes_only_owned_simulator(self):
        udid = "12345678-1234-1234-1234-123456789012"
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, udid),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "boot one failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown"),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "boot two failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "deleted"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, json.dumps({"devices": {"runtime": []}})),
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
            mock.patch.object(compatibility_matrix.time, "sleep"),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "after one retry"),
        ):
            compatibility_matrix._create_simulator(
                [("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro")],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=Path(temporary) / "simulator-diagnostics",
            )

        self.assertEqual(run.call_args_list[-2].args[0][2:4], ["delete", udid])

    def test_fixture_constructor_releases_local_servers_when_listener_gate_fails(self):
        server = mock.Mock(server_port=19450)
        thread = mock.Mock()
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix.LocalRuntimeFixture, "_prepare_tools"),
            mock.patch.object(compatibility_matrix.LocalRuntimeFixture, "_prepare_sshd"),
            mock.patch.object(
                compatibility_matrix.http.server, "ThreadingHTTPServer", return_value=server
            ),
            mock.patch.object(compatibility_matrix.threading, "Thread", return_value=thread),
            mock.patch.object(
                compatibility_matrix, "_require_loopback_listener",
                side_effect=compatibility_matrix.MatrixError("listener probe timed out"),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "listener probe timed out"),
        ):
            compatibility_matrix.LocalRuntimeFixture(Path(temporary), (), {})
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()
        thread.join.assert_called_once_with(timeout=5)


class DiagnosticArgumentsTests(unittest.TestCase):
    def test_fixture_startup_logs_are_retained_with_task_paths_redacted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "command-logs" / "pi-version.log"
            source.parent.mkdir(parents=True)
            source.write_text(f"pi v0.73.1 from {root}\n", encoding="utf-8")
            destination = root / "artifacts"

            with mock.patch.dict(
                compatibility_matrix.os.environ,
                {"CI_DIAGNOSTIC_ARTIFACTS_PATH": str(destination)},
                clear=False,
            ):
                retained = compatibility_matrix._retain_fixture_startup_diagnostics(root)

            self.assertEqual(retained, ["command-logs__pi-version.log"])
            safe_log = (destination / "fixture-startup" / retained[0]).read_text(encoding="utf-8")
            self.assertIn("pi v0.73.1", safe_log)
            self.assertNotIn(str(root), safe_log)

    def test_diagnostic_requires_build_number_and_captured_report_path(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main(["--diagnostic"])
        self.assertEqual(error.exception.code, 2)

    def test_native_probe_requires_build_number_and_captured_report_path(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main(["--native-probe"])
        self.assertEqual(error.exception.code, 2)

    def test_native_probe_passes_explicit_plan_and_output_to_native_runner(self):
        output = Path("/tmp/native-report.json")
        with mock.patch.object(compatibility_matrix, "run_native_probe") as run:
            self.assertEqual(
                compatibility_matrix.main(
                    ["--native-probe", "--build-number", "86", "--output", str(output)]
                ),
                0,
            )
        run.assert_called_once_with(planned_build_number=86, diagnostic_output=output)

    def test_native_probe_cannot_be_combined_with_full_diagnostic(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main([
                "--native-probe", "--diagnostic", "--build-number", "86", "--output", "/tmp/report.json",
            ])
        self.assertEqual(error.exception.code, 2)

    def test_pi_recorder_logs_timing_and_safe_argument_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shim_dir = root / "shim"
            shim_dir.mkdir()
            fake_pi = root / "pi"
            fake_pi.write_text("#!/bin/sh\nprintf 'pi 0.73.1\\n'\n", encoding="utf-8")
            fake_pi.chmod(0o700)
            fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
            fixture.root = root
            fixture.shim_dir = shim_dir
            command = fixture._install_pi_invocation_recorder(fake_pi)
            log = root / "pi-process.log"
            env = {
                **compatibility_matrix.os.environ,
                "TUNER_NATIVE_PROBE_LOG": str(log),
                "TUNER_NATIVE_PROBE_PHASE": "4082-standalone-version",
            }
            result = compatibility_matrix.subprocess.run(
                [str(command), "--version"], env=env, text=True, capture_output=True, check=False
            )

            self.assertEqual(result.returncode, 0)
            self.assertIn("0.73.1", result.stdout)
            records = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            self.assertEqual([item["event"] for item in records], ["start", "finish"])
            self.assertEqual(records[0]["argvShape"], ["--version"])
            self.assertEqual(records[1]["exitCode"], 0)
            self.assertGreaterEqual(records[1]["elapsedMs"], 0)

    def test_native_probe_pairs_gateway_and_standalone_pi_timing_without_raw_args(self):
        records = [
            {
                "event": "start", "invocationId": "one", "argvShape": ["--version"],
                "argumentCount": 1, "startedMonotonicNs": 1,
            },
            {
                "event": "finish", "invocationId": "one", "elapsedMs": 12,
                "result": "exited", "exitCode": 0,
            },
        ]

        summary = compatibility_matrix._first_pi_invocation_summary(records)

        self.assertEqual(summary, {
            "argvShape": ["--version"],
            "argumentCount": 1,
            "finished": True,
            "elapsedMs": 12,
            "result": "exited",
            "exitCode": 0,
        })
        self.assertNotIn("startedMonotonicNs", summary)
        self.assertNotIn("invocationId", summary)

    def test_native_probe_requires_observed_successful_gateway_pi_process(self):
        self.assertTrue(compatibility_matrix._gateway_readiness_has_completed_pi({
            "gatewayReadiness": {
                "status": "ready",
                "piReadinessInvocation": {"finished": True, "exitCode": 0},
            },
        }))
        self.assertFalse(compatibility_matrix._gateway_readiness_has_completed_pi({
            "gatewayReadiness": {"status": "ready", "piReadinessInvocation": None},
        }))
        self.assertFalse(compatibility_matrix._gateway_readiness_has_completed_pi({
            "gatewayReadiness": {
                "status": "ready",
                "piReadinessInvocation": {"finished": False, "exitCode": None},
            },
        }))

    def test_native_probe_report_failure_sets_a_failing_ci_exit(self):
        with self.assertRaises(compatibility_matrix.MatrixError):
            compatibility_matrix._ensure_native_probe_succeeded({
                "status": "failed",
                "failure": "focused probe did not observe a correlated reply",
            })
        compatibility_matrix._ensure_native_probe_succeeded({"status": "completed"})

    def test_native_probe_workflow_uses_hosted_route_without_simulator_command(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-note-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("runs-on: xcode-27", workflow)
        self.assertIn("--native-probe", workflow)
        self.assertNotIn("simctl", workflow)

    def test_diagnostic_passes_explicit_plan_and_output_to_matrix(self):
        output = Path("/tmp/compatibility-report.json")
        with mock.patch.object(compatibility_matrix, "run_matrix") as run:
            self.assertEqual(
                compatibility_matrix.main(
                    ["--diagnostic", "--build-number", "84", "--output", str(output)]
                ),
                0,
            )
        run.assert_called_once_with(
            diagnostic=True,
            planned_build_number=84,
            diagnostic_output=output,
        )

    def test_archive_cannot_receive_diagnostic_only_arguments(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main(["--build-number", "84", "--output", "/tmp/report.json"])
        self.assertEqual(error.exception.code, 2)

    def test_diagnostic_workflow_checks_out_and_reports_the_pull_request_head(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-note-gate.yml").read_text(
            encoding="utf-8"
        )
        expression = "${{ github.event.pull_request.head.sha || github.sha }}"
        self.assertEqual(workflow.count(expression), 3)
        self.assertIn(f"CI_COMMIT: {expression}", workflow)
        self.assertIn(f"ref: {expression}", workflow)

    def test_xcode_failure_summary_keeps_locations_but_not_sensitive_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "baseline.log"
            log_path.write_text(
                "/Volumes/private-task/ReleaseCompatibilityTests.swift:426: error: token=do-not-retain XCTAssertTrue failed - ssh-ed25519 key data\n"
                "xcodebuild: error: test failed\n",
                encoding="utf-8",
            )
            summary = compatibility_matrix._safe_xcode_failure_summary(log_path)

        self.assertEqual(summary["sourceLocations"], [
            {"file": "ReleaseCompatibilityTests.swift", "line": 426, "severity": "error"}
        ])
        self.assertEqual(summary["assertionKinds"], ["XCTAssertTrue"])
        self.assertEqual(summary["errorCount"], 2)
        self.assertNotIn("private-task", json.dumps(summary))
        self.assertNotIn("do-not-retain", json.dumps(summary))
        self.assertNotIn("ssh-ed25519", json.dumps(summary))

    def test_readable_ci_diagnostics_redact_fixture_values_and_private_identifiers(self):
        runtime_session = "aaa00-bb0000-11111111-2222-3333-4444-555555555555-aaaaaaaaaaaa"
        raw = (
            "Authorization: Bearer secret-bearer-value\n"
            "X-Test-Fixture-Token: fixture-token-value\n"
            "agent:main:clawline:temporary-user:main user_private_12345678\n"
            f"adapter session {runtime_session}\n"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIprivate host\n"
            "/private/task-root/fixture.log\n"
            "ReleaseCompatibilityTests.swift:426: error: XCTAssertTrue failed\n"
        )
        safe = compatibility_matrix._safe_diagnostic_text(
            raw,
            {"secret-bearer-value", "fixture-token-value", "/private/task-root"},
        )

        for secret in (
            "secret-bearer-value", "fixture-token-value", "agent:main:clawline",
            "user_private_12345678", "AAAAC3NzaC1lZDI1NTE5AAAAIprivate",
            "/private/task-root", runtime_session,
        ):
            self.assertNotIn(secret, safe)
        self.assertIn("ReleaseCompatibilityTests.swift:426: error: XCTAssertTrue failed", safe)

    def test_result_bundle_scan_detects_known_ephemeral_fixture_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "failure.xcresult"
            bundle.mkdir()
            (bundle / "data.bin").write_bytes(b"prefix-fixture-token-value-suffix")

            self.assertTrue(
                compatibility_matrix._contains_sensitive_bytes(bundle, {"fixture-token-value"})
            )

            (bundle / "data.bin").write_bytes(b"public diagnostic text only")
            self.assertFalse(
                compatibility_matrix._contains_sensitive_bytes(bundle, {"fixture-token-value"})
            )

    def test_runtime_log_export_includes_nested_logs_and_redacts_fixture_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime_session = "aaa00-bb0000-11111111-2222-3333-4444-555555555555-aaaaaaaaaaaa"
            runtime_log = (
                root / "runtime-state" / "4304" / "base"
                / f"adapter-pi_shared_{runtime_session}.stderr.log"
            )
            runtime_log.parent.mkdir(parents=True)
            runtime_log.write_text(
                f"{runtime_session} fixture-token-value roster loaded\n",
                encoding="utf-8",
            )
            host_key = root / "ssh-host-key"
            host_key.write_text("private-key-bytes", encoding="utf-8")

            fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
            fixture.root = root
            fixture.fixture_token = "fixture-token-value"
            fixture.local_user = "user_private_12345678"
            fixture.ssh_host_key_line = "ssh-ed25519 public-key-line"
            fixture.home_root = root / "home"
            fixture.package_paths = {}
            fixture.runtime_base = {}
            fixture.runtime_identities = {}
            fixture.saved_state = {}
            fixture.phase_results = []
            fixture.host_key = host_key

            destination = root / "retained"
            retained = fixture.export_safe_runtime_logs(destination)
            self.assertEqual(len(retained), 1)
            exported = destination / retained[0]
            safe = exported.read_text(encoding="utf-8")
            self.assertIn("roster loaded", safe)
            self.assertNotIn("fixture-token-value", safe)
            self.assertNotIn(runtime_session, exported.name)
            self.assertNotIn("aaa00-bb0000", exported.name)
            self.assertNotIn(runtime_session, safe)
            self.assertIn("runtime-state__4304__base__", exported.name)

    def test_failure_artifact_workflow_uploads_report_and_diagnostics(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-note-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'export CI_DIAGNOSTIC_ARTIFACTS_PATH="$RUNNER_TEMP/TunerCompatibilityDiagnostics"',
            workflow,
        )
        self.assertIn("${{ runner.temp }}/ReleaseCompatibilityReport.json", workflow)
        self.assertIn("${{ runner.temp }}/TunerCompatibilityDiagnostics/", workflow)
        self.assertIn("if-no-files-found: error", workflow)


class PublishedRuntimeProbeTests(unittest.TestCase):
    def test_first_probe_failure_does_not_skip_second_published_runtime(self):
        class Fixture:
            def __init__(self):
                self.calls = []
                self.runtime_turn_probes = []

            def preflight_runtime_reply(self, release):
                self.calls.append(release.tag)
                status = "failed" if release.tag == "v0.1.16+4304" else "passed"
                self.runtime_turn_probes.append({"tag": release.tag, "status": status})
                return status == "passed"

        fixture = Fixture()
        releases = (
            SimpleNamespace(tag="v0.1.16+4304"),
            SimpleNamespace(tag="v0.1.15+4082"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "report.json"
            report = {}
            failures = compatibility_matrix._probe_published_runtime_turns(
                fixture, releases, report, report_path
            )
            retained = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(fixture.calls, ["v0.1.16+4304", "v0.1.15+4082"])
        self.assertEqual(failures, ["v0.1.16+4304"])
        self.assertEqual(
            [probe["status"] for probe in retained["runtimeTurnProbes"]],
            ["failed", "passed"],
        )
        self.assertEqual(retained["stage"], "runtime_turn_probe_completed:v0.1.15+4082")


if __name__ == "__main__":
    unittest.main()
