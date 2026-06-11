import socket
import threading
import json


class ChatServer:

    def __init__(self, port, callback):

        self.port = port
        self.callback = callback

    def start(self):

        threading.Thread(
            target=self.run,
            daemon = True
        ).start()
    
    def run(self):

        server = socket.socket(
            socket.AF_INET,
            socket.SOCK_STREAM
        )

        server.bind(
            ("0.0.0.0", self.port)
        )

        server.listen()

        while True:

            conn, addr = server.accept()

            threading.Thread(
                target=self.handle_client,
                args=(conn,),
                daemon=True
            ).start()
        
    def handle_client(self, conn):

        try:

            data = conn.recv(
                4096
            )

            packet = json.loads(
                data.decode()
            )

            self.callback(
                packet
            )
            
        except:
            pass
            
        finally:
            conn.close()