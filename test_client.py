import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN = "test_token_123"
ROOT = os.path.abspath(os.path.dirname(__file__))
CONNECTORS_PATH = os.path.join(ROOT, "mock-connector")


def log(msg):
    print(f"[TEST] {msg}")


def read_sse_json(response, expected_event="message"):
    event_name = None
    for _ in range(30):
        line = response.readline().decode("utf-8").strip()
        if not line:
            continue
        log(f"Received line: {line}")
        if line.startswith("event:"):
            event_name = line.split(":", 1)[1].strip()
        elif line.startswith("data:") and event_name == expected_event:
            data_val = line.split(":", 1)[1].strip()
            return json.loads(data_val)
    raise AssertionError(f"Did not receive SSE {expected_event!r} event")


def read_endpoint(response):
    event_name = None
    for _ in range(20):
        line = response.readline().decode("utf-8").strip()
        if not line:
            continue
        log(f"Received line: {line}")
        if line.startswith("event:"):
            event_name = line.split(":", 1)[1].strip()
        elif line.startswith("data:") and event_name == "endpoint":
            return line.split(":", 1)[1].strip()
    raise AssertionError("Did not receive endpoint handshake event")


def request(url, data=None, method=None):
    headers = {"Authorization": f"Bearer {TOKEN}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json, text/event-stream"
    else:
        headers["Accept"] = "text/event-stream"
    return urllib.request.Request(url, data=data, headers=headers, method=method)


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def write_isolated_config(config_home, port):
    config = {
        "token": TOKEN,
        "port": port,
        "publicBaseURL": f"http://localhost:{port}",
        "bindHost": "127.0.0.1",
        "allowedOrigins": [
            f"http://localhost:{port}",
            f"http://127.0.0.1:{port}",
            f"http://[::1]:{port}",
        ],
        "allowQueryTokenAuth": True,
        "connectorsPath": CONNECTORS_PATH,
        "additionalConnectorPaths": [],
        "importedConnectors": {},
        "connectorSettings": {
            "mock-echo": {
                "enabled": True,
                "exposePublicly": True,
                "publicPath": "mock-echo",
            },
        },
        "onePasswordEnvironment": {
            "enabled": False,
            "accountId": "",
            "environmentId": "",
            "environmentName": "",
            "localEnvFilePath": "",
        },
        "env": {},
        "disabledConnectors": [],
    }
    with open(os.path.join(config_home, "config.json"), "w", encoding="utf-8") as fh:
        json.dump(config, fh)


def run_tests():
    server_process = None
    stdout_file = None
    stderr_file = None
    with tempfile.TemporaryDirectory(prefix="bridgeport-smoke-") as config_home:
        port = find_free_port()
        try:
            log("Ensuring build is fresh...")
            subprocess.run(["swift", "build"], cwd=ROOT, check=True)
            write_isolated_config(config_home, port)

            exec_path = os.path.join(ROOT, ".build/debug/bridgeport")
            if not os.path.exists(exec_path):
                exec_path = os.path.join(ROOT, ".build/out/Products/Debug/bridgeport")
            if not os.path.exists(exec_path):
                raise FileNotFoundError("Could not find bridgeport binary")

            stdout_file = open(os.path.join(config_home, "server_stdout.log"), "w")
            stderr_file = open(os.path.join(config_home, "server_stderr.log"), "w")
            env = os.environ.copy()
            env["BRIDGEPORT_CONFIG_HOME"] = config_home

            log(f"Starting Bridgeport server on port {port} with isolated config {config_home}...")
            server_process = subprocess.Popen(
                [
                    exec_path,
                    "--server",
                    "--port", str(port),
                    "--token", TOKEN,
                    "--connectors-path", CONNECTORS_PATH,
                    "--bind-host", "127.0.0.1",
                ],
                cwd=ROOT,
                stdout=stdout_file,
                stderr=stderr_file,
                env=env,
            )

            time.sleep(1.5)

            log("Test 1: Connecting without token...")
            try:
                urllib.request.urlopen(f"http://localhost:{port}/mock-echo/sse", timeout=5)
                raise AssertionError("Connected without authorization")
            except urllib.error.HTTPError as e:
                if e.code != 401:
                    raise
                auth_header = e.headers.get("WWW-Authenticate", "")
                if "Bearer" not in auth_header:
                    raise AssertionError(f"Expected Bearer auth challenge, got {auth_header!r}")
                log("PASS: Received 401 Unauthorized as expected")

            log("Test 2: Legacy SSE handshake with Authorization header...")
            response = urllib.request.urlopen(request(f"http://localhost:{port}/mock-echo/sse"), timeout=10)
            endpoint_path = read_endpoint(response)
            log(f"PASS: Received endpoint handshake event: {endpoint_path}")

            log("Test 3: Legacy POST message...")
            payload = {
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/list",
                "params": {},
            }
            post_url = f"http://localhost:{port}{endpoint_path}"
            post_res = urllib.request.urlopen(request(post_url, json.dumps(payload).encode("utf-8")), timeout=10)
            if post_res.code not in (200, 202):
                raise AssertionError(f"Expected 200/202 from legacy POST, got {post_res.code}")
            log("PASS: Legacy POST accepted")

            log("Test 4: Legacy SSE response...")
            response_event = read_sse_json(response)
            if response_event.get("id") != 42:
                raise AssertionError(f"Expected response ID 42, got {response_event.get('id')}")
            log("PASS: Legacy SSE response matched request")

            log("Test 5: Streamable HTTP /mcp POST...")
            payload["id"] = 7
            mcp_req = request(f"http://localhost:{port}/mcp/mock-echo", json.dumps(payload).encode("utf-8"))
            mcp_response = urllib.request.urlopen(mcp_req, timeout=10)
            session_id = mcp_response.headers.get("Mcp-Session-Id")
            if not session_id:
                raise AssertionError("Streamable HTTP response did not include Mcp-Session-Id")
            mcp_event = read_sse_json(mcp_response)
            if mcp_event.get("id") != 7:
                raise AssertionError(f"Expected response ID 7, got {mcp_event.get('id')}")
            log("PASS: Streamable HTTP response matched request")

            log("Test 6: Streamable HTTP query-token fallback...")
            payload["id"] = 8
            query_headers = {
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
            }
            query_req = urllib.request.Request(
                f"http://localhost:{port}/mcp/mock-echo?token={TOKEN}",
                data=json.dumps(payload).encode("utf-8"),
                headers=query_headers,
            )
            query_response = urllib.request.urlopen(query_req, timeout=10)
            query_event = read_sse_json(query_response)
            if query_event.get("id") != 8:
                raise AssertionError(f"Expected response ID 8, got {query_event.get('id')}")
            log("PASS: Query-token fallback response matched request")

            log("Test 7: Runtime status endpoint...")
            status_response = urllib.request.urlopen(
                urllib.request.Request(
                    f"http://localhost:{port}/status",
                    headers={"Authorization": f"Bearer {TOKEN}"},
                ),
                timeout=10,
            )
            status = json.loads(status_response.read().decode("utf-8"))
            if "connectors" not in status or not status["connectors"]:
                raise AssertionError("Status endpoint did not return connectors")
            log("PASS: Status endpoint returned connector runtime data")

            log("Test 8: Public connector icons support HEAD and GET...")
            icon_url = f"http://localhost:{port}/icons/mock-echo"
            head_response = urllib.request.urlopen(
                urllib.request.Request(icon_url, method="HEAD"),
                timeout=10,
            )
            if head_response.code != 200:
                raise AssertionError(f"Expected 200 from icon HEAD, got {head_response.code}")
            icon_type = head_response.headers.get("Content-Type", "")
            if not icon_type.startswith("image/"):
                raise AssertionError(f"Expected image content type from icon HEAD, got {icon_type!r}")
            icon_response = urllib.request.urlopen(urllib.request.Request(icon_url), timeout=10)
            icon_body = icon_response.read()
            if not icon_body:
                raise AssertionError("Icon GET returned an empty body")
            log("PASS: Public icon endpoint handles HEAD and GET")

            log("Test 9: OAuth authorization requires a scoped public resource...")
            register_req = urllib.request.Request(
                f"http://localhost:{port}/oauth/register",
                data=json.dumps({
                    "client_name": "Smoke Test",
                    "redirect_uris": ["http://localhost/callback"],
                }).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            register_response = urllib.request.urlopen(register_req, timeout=10)
            client_id = json.loads(register_response.read().decode("utf-8"))["client_id"]
            authorize_params = {
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": "http://localhost/callback",
                "code_challenge": "test-challenge",
                "code_challenge_method": "S256",
            }
            try:
                urllib.request.urlopen(
                    f"http://localhost:{port}/oauth/authorize?{urllib.parse.urlencode(authorize_params)}",
                    timeout=10,
                )
                raise AssertionError("Expected OAuth authorization without resource to be rejected")
            except urllib.error.HTTPError as e:
                if e.code != 400:
                    raise
            authorize_params["resource"] = f"http://localhost:{port}/mcp/mock-echo"
            authorize_response = urllib.request.urlopen(
                f"http://localhost:{port}/oauth/authorize?{urllib.parse.urlencode(authorize_params)}",
                timeout=10,
            )
            if authorize_response.code != 200:
                raise AssertionError(f"Expected OAuth approval form, got {authorize_response.code}")
            log("PASS: OAuth authorization rejects missing resource and accepts public connector resource")

            log("Test 10: Disallowed Origin is rejected...")
            bad_origin_req = request(
                f"http://localhost:{port}/mcp/mock-echo",
                json.dumps(payload).encode("utf-8"),
            )
            bad_origin_req.add_header("Origin", "https://evil.example")
            try:
                urllib.request.urlopen(bad_origin_req, timeout=10)
                raise AssertionError("Expected disallowed Origin to be rejected")
            except urllib.error.HTTPError as e:
                if e.code != 403:
                    raise
                log("PASS: Disallowed Origin rejected")

            log("Test 11: Oversized MCP request body is rejected...")
            oversized_req = request(
                f"http://localhost:{port}/mcp/mock-echo",
                b"x" * (1024 * 1024 + 1),
            )
            try:
                urllib.request.urlopen(oversized_req, timeout=10)
                raise AssertionError("Expected oversized request to be rejected")
            except urllib.error.HTTPError as e:
                if e.code != 413:
                    raise
                log("PASS: Oversized MCP request rejected")

            log("Test 12: Streamable HTTP session DELETE...")
            delete_req = urllib.request.Request(
                f"http://localhost:{port}/mcp/mock-echo",
                headers={
                    "Authorization": f"Bearer {TOKEN}",
                    "Mcp-Session-Id": session_id,
                },
                method="DELETE",
            )
            delete_res = urllib.request.urlopen(delete_req, timeout=10)
            if delete_res.code != 202:
                raise AssertionError(f"Expected 202 from session DELETE, got {delete_res.code}")
            try:
                urllib.request.urlopen(delete_req, timeout=10)
                raise AssertionError("Expected DELETE of closed session to return 404")
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
            log("PASS: Streamable HTTP session DELETE closes and forgets the session")

            config_path = os.path.join(config_home, "config.json")
            client_config_path = os.path.join(config_home, "mcp_config.json")
            cloud_config_path = os.path.join(config_home, "cloud_connectors.json")
            if not os.path.exists(config_path) or not os.path.exists(client_config_path) or not os.path.exists(cloud_config_path):
                raise AssertionError("Isolated config files were not written")
            log("PASS: Isolated config home used for generated files")

            log("ALL TESTS COMPLETED SUCCESSFULLY!")
        finally:
            if server_process:
                log("Stopping Bridgeport server...")
                server_process.terminate()
                try:
                    server_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server_process.kill()
                    server_process.wait()
                log("Server stopped.")
            if stdout_file:
                stdout_file.close()
            if stderr_file:
                stderr_file.close()


if __name__ == "__main__":
    run_tests()
