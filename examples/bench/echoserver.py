import argparse
import asyncio
import gc
import os.path
import socket as socket_module

from socket import *


PRINT = 0


async def echo_server(loop, address, unix):
    if unix:
        sock = socket(AF_UNIX, SOCK_STREAM)
    else:
        sock = socket(AF_INET, SOCK_STREAM)
        sock.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1)
    sock.bind(address)
    sock.listen(5)
    sock.setblocking(False)
    if PRINT:
        print('Server listening at', address)
    with sock:
        while True:
            client, addr = await loop.sock_accept(sock)
            if PRINT:
                print('Connection from', addr)
            loop.create_task(echo_client(loop, client))


async def echo_client(loop, client):
    try:
        client.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
    except (OSError, NameError):
        pass

    with client:
        while True:
            data = await loop.sock_recv(client, 1000000)
            if not data:
                break
            await loop.sock_sendall(client, data)
    if PRINT:
        print('Connection closed')


async def echo_client_streams(reader, writer):
    sock = writer.get_extra_info('socket')
    try:
        sock.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
    except (OSError, NameError):
        pass
    if PRINT:
        print('Connection from', sock.getpeername())
    while True:
        data = await reader.read(1000000)
        if not data:
            break
        writer.write(data)
    if PRINT:
        print('Connection closed')
    writer.close()


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def connection_lost(self, exc):
        self.transport = None

    def data_received(self, data):
        self.transport.write(data)


async def print_debug(loop):
    while True:
        print(chr(27) + "[2J")  # clear screen
        loop.print_debug_info()
        await asyncio.sleep(0.5, loop=loop)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--uvloop', default=False, action='store_true')
    parser.add_argument('--streams', default=False, action='store_true')
    parser.add_argument('--proto', default=False, action='store_true')
    parser.add_argument('--addr', default='127.0.0.1:25000', type=str)
    parser.add_argument('--print', default=False, action='store_true')
    args = parser.parse_args()

    if args.uvloop:
        import uvloop
        loop = uvloop.new_event_loop()
        print('using UVLoop')
    else:
        loop = asyncio.new_event_loop()
        print('using asyncio loop')

    asyncio.set_event_loop(loop)
    loop.set_debug(False)

    if args.print:
        PRINT = 1

    if hasattr(loop, 'print_debug_info'):
        loop.create_task(print_debug(loop))
        PRINT = 0

    unix = False
    if args.addr.startswith('file:'):
        unix = True
        addr = args.addr[5:]
        if os.path.exists(addr):
            os.remove(addr)
    else:
        addr = args.addr.split(':')
        addr[1] = int(addr[1])
        addr = tuple(addr)

    print('serving on: {}'.format(addr))

    if args.streams:
        if args.proto:
            print('cannot use --stream and --proto simultaneously')
            exit(1)

        print('using asyncio/streams')
        if unix:
            coro = asyncio.start_unix_server(echo_client_streams,
                                             addr, loop=loop)
        else:
            coro = asyncio.start_server(echo_client_streams,
                                        *addr, loop=loop)
        srv = loop.run_until_complete(coro)
    elif args.proto:
        if args.streams:
            print('cannot use --stream and --proto simultaneously')
            exit(1)

        print('using simple protocol')
        if unix:
            coro = loop.create_unix_server(EchoProtocol, addr)
        else:
            coro = loop.create_server(EchoProtocol, *addr)
        srv = loop.run_until_complete(coro)
    else:
        print('using sock_recv/sock_sendall')
        loop.create_task(echo_server(loop, addr, unix))
    try:
        loop.run_forever()
    finally:
        if hasattr(loop, 'print_debug_info'):
            gc.collect()
            print(chr(27) + "[2J")
            loop.print_debug_info()

        loop.close()
