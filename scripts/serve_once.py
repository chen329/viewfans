"""1つのファイルを、指定した相手に1回だけ渡して終了する簡易 Web サーバー。

使い方: python3 serve_once.py <ファイル> <ポート> <受け取る側のIP>
"""
import http.server
import os
import sys

path, port, allowed = sys.argv[1], int(sys.argv[2]), sys.argv[3]
done = False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global done
        if self.client_address[0] != allowed:
            self.send_error(403)
            return
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            while chunk := f.read(1024 * 1024):
                self.wfile.write(chunk)
        done = True

    def log_message(self, fmt, *args):
        print(f"  {self.client_address[0]} {fmt % args}")


server = http.server.HTTPServer(("0.0.0.0", port), Handler)
print(f"  待ち受け中(ポート {port}、{allowed} からのみ)。Ctrl+C で中止")
try:
    while not done:
        server.handle_request()
except KeyboardInterrupt:
    print("  中止しました")
    sys.exit(1)
finally:
    server.server_close()
