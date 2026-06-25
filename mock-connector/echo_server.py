import sys
import json

print("Mock Echo MCP Server started", file=sys.stderr, flush=True)

while True:
    line = sys.stdin.readline()
    if not line:
        break
    try:
        trimmed = line.strip()
        if not trimmed:
            continue
        data = json.loads(trimmed)
        # Echo the request back as an RPC response
        response = {
            "jsonrpc": "2.0",
            "id": data.get("id"),
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": f"Echo: {json.dumps(data)}"
                    }
                ]
            }
        }
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    except Exception as e:
        sys.stderr.write(f"Error in mock: {e}\n")
        sys.stderr.flush()
