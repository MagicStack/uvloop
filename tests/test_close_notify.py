import asyncio
import ssl
import threading
import time
import unittest

from uvloop import _testbase as tb


class TestCloseNotify(tb.SSLTestCase, tb.UVTestCase):

    ONLYCERT = tb._cert_fullname(__file__, 'ssl_cert.pem')
    ONLYKEY = tb._cert_fullname(__file__, 'ssl_key.pem')

    PAYLOAD_SIZE = 1024 * 50
    TIMEOUT = 10

    HELLO_MSG = b'A' * PAYLOAD_SIZE
    END_MSG = b'THE END'

    class ClientProto(asyncio.Protocol):

        def __init__(self, conn_lost):
            self.transport = None
            self.conn_lost = conn_lost
            self.buffered_bytes = 0
            self.total_bytes = 0

        def connection_made(self, tr):
            self.transport = tr

        def data_received(self, data):
            self.buffered_bytes += len(data)
            self.total_bytes += len(data)

            if self.transport.is_reading() and self.buffered_bytes >= TestCloseNotify.PAYLOAD_SIZE:
                print("app pause_reading")
                self.transport.pause_reading()

        def eof_received(self):
            print("app eof_received")

        def connection_lost(self, exc):
            print(f"finally received: {self.total_bytes}")
            self.conn_lost.set_result(None)

    def test_close_notify(self):

        conn_lost = self.loop.create_future()

        def server(sock):

            incoming = ssl.MemoryBIO()
            outgoing = ssl.MemoryBIO()

            server_context = self._create_server_ssl_context(self.ONLYCERT, self.ONLYKEY)
            sslobj = server_context.wrap_bio(incoming, outgoing, server_side=True)

            while True:
                try:
                    sslobj.do_handshake()
                except ssl.SSLWantReadError:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    incoming.write(sock.recv(16384))
                else:
                    if outgoing.pending:
                        sock.send(outgoing.read())
                    break

            # first send: 1024 * 50 bytes
            sslobj.write(self.HELLO_MSG)
            sock.send(outgoing.read())

            time.sleep(1)

            # then send: 7 bytes
            sslobj.write(self.END_MSG)
            sock.send(outgoing.read())

            # send close_notify but don't wait for response
            with self.assertRaises(ssl.SSLWantReadError):
                sslobj.unwrap()
            sock.send(outgoing.read())

            sock.close()

        async def client(addr):
            cp = TestCloseNotify.ClientProto(conn_lost)
            client_context = self._create_client_ssl_context()
            tr, proto = await self.loop.create_connection(lambda: cp, *addr, ssl=client_context)

            # app read buffer and do some logic in 3 seconds
            await asyncio.sleep(3)
            cp.buffered_bytes = 0
            # app finish operation, resume reading more from buffer
            tr.resume_reading()

            await asyncio.wait_for(conn_lost, timeout=self.TIMEOUT)
            await asyncio.sleep(3)
            tr.close()

        test_server = self.tcp_server(server)
        port = test_server._sock.getsockname()[1]
        thread1 = threading.Thread(target=lambda : test_server.start())
        thread2 = threading.Thread(target=lambda : self.loop.run_until_complete(client(('127.0.0.1', port))))

        thread1.start()
        thread2.start()

        thread1.join()
        thread2.join()


if __name__ == "__main__":
    unittest.main()
