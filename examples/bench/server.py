import argparse
import asyncio
import uvloop

from socket import *


async def echo_server(loop, address):
    sock = socket(AF_INET, SOCK_STREAM)
    sock.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1)
    sock.bind(address)
    sock.listen(5)
    sock.setblocking(False)
    print('Server listening at', address)
    with sock:
        while True:
             client, addr = await loop.sock_accept(sock)
             print('Connection from', addr)
             loop.create_task(echo_client(loop, client))


async def echo_client(loop, client):
    with client:
         while True:
             data = await loop.sock_recv(client, 10000)
             if not data:
                  break
             await loop.sock_sendall(client, data)
    print('Connection closed')


async def echo_client_streams(reader, writer):
    sock = writer.get_extra_info('socket')
    print('Connection from', sock.getpeername())
    while True:
         data = await reader.read(10000)
         if not data:
             break
         writer.write(data)
         await writer.drain()
    print('Connection closed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--uvloop', default=False, action='store_true')
    parser.add_argument('--streams', default=False, action='store_true')
    args = parser.parse_args()

    if args.uvloop:
        loop = uvloop.Loop()
        print('using UVLoop')
    else:
        loop = asyncio.new_event_loop()
        print('using asyncio loop')

    asyncio.set_event_loop(loop)
    loop.set_debug(False)

    if args.streams:
        print('using asyncio/streams')
        coro = asyncio.start_server(echo_client_streams,
                                    '127.0.0.1', 25000, loop=loop)
        loop.create_task(coro)
    else:
        print('using sock_recv/sock_sendall')
        loop.create_task(echo_server(loop, ('', 25000)))
    try:
        loop.run_forever()
    finally:
        loop.close()
