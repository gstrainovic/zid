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
    import subprocess
    print("Building vulkan-ed...")
    subprocess.run(["zig", "build"], check=True)

    if len(sys.argv) < 2:
        print("Usage: rpc_open.py <method> [params...]")
        sys.exit(1)
        
    method = sys.argv[1]
    params = sys.argv[2:]
    
    # Integers parsen falls möglich
    parsed_params = []
    for p in params:
        try:
            parsed_params.append(int(p))
        except ValueError:
            parsed_params.append(p)
            
    print(f"Sending RPC {method}({parsed_params})...")
    res = send_rpc(method, parsed_params)
    print(json.dumps(res, indent=2))
