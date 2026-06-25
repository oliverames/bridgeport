import subprocess
import time
import urllib.request
import urllib.parse
import json
import sys
import os

PORT = 8085
TOKEN = "test_token_123"
CONNECTORS_PATH = "/Users/oliverames/.gemini/antigravity/scratch/bridgeport"

def log(msg):
    print(f"[TEST] {msg}")

def run_tests():
    server_process = None
    try:
        # Build bridgeport executable first
        log("Ensuring build is fresh...")
        subprocess.run(["swift", "build"], check=True)
        
        # Locate executable
        exec_path = ".build/debug/bridgeport"
        if not os.path.exists(exec_path):
            exec_path = ".build/out/Products/Debug/bridgeport"
            if not os.path.exists(exec_path):
                raise FileNotFoundError("Could not find bridgeport binary")
        
        # Start server
        log(f"Starting Bridgeport server on port {PORT}...")
        stdout_file = open("server_stdout.log", "w")
        stderr_file = open("server_stderr.log", "w")
        server_process = subprocess.Popen([
            exec_path,
            "--port", str(PORT),
            "--token", TOKEN,
            "--connectors-path", CONNECTORS_PATH
        ], stdout=stdout_file, stderr=stderr_file)
        
        # Wait for server to start
        time.sleep(1.5)
        
        # 1. Test Unauthorized SSE Connection
        log("Test 1: Connecting without token...")
        try:
            urllib.request.urlopen(f"http://localhost:{PORT}/mock-echo/sse")
            log("FAIL: Connected without authorization")
            sys.exit(1)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                log("PASS: Received 401 Unauthorized as expected")
            else:
                log(f"FAIL: Expected 401 but got {e.code}")
                sys.exit(1)

        # 2. Test Authorized SSE Connection & Handshake
        log("Test 2: Connecting with valid token in query param...")
        sse_url = f"http://localhost:{PORT}/mock-echo/sse?token={TOKEN}"
        
        req = urllib.request.Request(sse_url)
        # We will open the stream and read the first event (endpoint handshake)
        response = urllib.request.urlopen(req)
        
        log("Connected successfully to SSE stream. Waiting for endpoint handshake...")
        
        # Read lines until we get the endpoint data
        endpoint_path = None
        event_name = None
        
        for _ in range(10):
            line = response.readline().decode('utf-8').strip()
            if not line:
                continue
            log(f"Received line: {line}")
            if line.startswith("event:"):
                event_name = line.split(":", 1)[1].strip()
            elif line.startswith("data:"):
                data_val = line.split(":", 1)[1].strip()
                if event_name == "endpoint":
                    endpoint_path = data_val
                    break
        
        if not endpoint_path:
            log("FAIL: Did not receive endpoint handshake event")
            sys.exit(1)
            
        log(f"PASS: Received endpoint handshake event: {endpoint_path}")
        
        # 3. Test sending a message (POST to the endpoint path)
        log("Test 3: Sending client message (POST)...")
        # Resolve full URL
        post_url = f"http://localhost:{PORT}{endpoint_path}&token={TOKEN}"
        log(f"POST URL: {post_url}")
        
        payload = {
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/list",
            "params": {}
        }
        
        post_data = json.dumps(payload).encode('utf-8')
        post_req = urllib.request.Request(
            post_url,
            data=post_data,
            headers={"Content-Type": "application/json"}
        )
        
        post_res = urllib.request.urlopen(post_req)
        if post_res.code == 200:
            log("PASS: POST request completed successfully with 200 OK")
        else:
            log(f"FAIL: POST request returned {post_res.code}")
            sys.exit(1)
            
        # 4. Read back the response from the SSE stream
        log("Test 4: Reading response from SSE stream...")
        response_event = None
        event_name = None
        
        for _ in range(10):
            line = response.readline().decode('utf-8').strip()
            if not line:
                continue
            log(f"Received line: {line}")
            if line.startswith("event:"):
                event_name = line.split(":", 1)[1].strip()
            elif line.startswith("data:"):
                data_val = line.split(":", 1)[1].strip()
                if event_name == "message":
                    response_event = json.loads(data_val)
                    break
                    
        if not response_event:
            log("FAIL: Did not receive response message on SSE stream")
            sys.exit(1)
            
        log(f"Received JSON-RPC message: {response_event}")
        
        # Verify JSON-RPC matches the expected structure and echoes our payload
        if response_event.get("id") == 42:
            echoed_text = response_event.get("result", {}).get("content", [{}])[0].get("text", "")
            if "Echo:" in echoed_text and '"id": 42' in echoed_text:
                log("PASS: Response JSON matches request id and contains echoed payload!")
            else:
                log("FAIL: Response contents do not match expected echo format")
                sys.exit(1)
        else:
            log(f"FAIL: Expected response ID 42 but got {response_event.get('id')}")
            sys.exit(1)
            
        log("ALL TESTS COMPLETED SUCCESSFULLY!")
        
    finally:
        if server_process:
            log("Stopping Bridgeport server...")
            server_process.terminate()
            server_process.wait()
            log("Server stopped.")
        try:
            stdout_file.close()
            stderr_file.close()
        except:
            pass

if __name__ == "__main__":
    run_tests()
