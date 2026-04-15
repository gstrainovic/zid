import socket
import json
import sys

def send_rpc(method, params=[]):
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }
    msg = json.dumps(payload) + "\n"
    
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect(("127.0.0.1", 9999))
        s.sendall(msg.encode())
        response = s.recv(4096).decode()
        return json.loads(response)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: rpc_open.py <file_path>")
        sys.exit(1)
        
    path = sys.argv[1]
    print(f"Opening file via RPC: {path}")
    res = send_rpc("open_file", [path])
    print(json.dumps(res, indent=2))
