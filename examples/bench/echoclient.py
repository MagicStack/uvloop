# Copied with minimal modifications from curio
# https://github.com/dabeaz/curio

from concurrent.futures import ProcessPoolExecutor

import argparse
from socket import *
import time
import sys

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--msize', default=1000, type=int,
                        help='message size in bytes')
    parser.add_argument('--num', default=200000, type=int,
                        help='number of messages')
    parser.add_argument('--times', default=1, type=int,
                        help='number of times to run the test')
    parser.add_argument('--workers', default=3, type=int,
                        help='number of workers')
    parser.add_argument('--addr', default='127.0.0.1:25000', type=str,
                        help='number of workers')
    args = parser.parse_args()

    unix = False
    if args.addr.startswith('file:'):
        unix = True
        addr = args.addr[5:]
    else:
        addr = args.addr.split(':')
        addr[1] = int(addr[1])
        addr = tuple(addr)
    print('will connect to: {}'.format(addr))

    MSGSIZE = args.msize

    msg = b'x'*MSGSIZE

    def run_test(n):
        print('Sending', NMESSAGES, 'messages')
        if unix:
            sock = socket(AF_UNIX, SOCK_STREAM)
        else:
            sock = socket(AF_INET, SOCK_STREAM)
        sock.connect(addr)
        while n > 0:
            sock.sendall(msg)
            nrecv = 0
            while nrecv < MSGSIZE:
                resp = sock.recv(MSGSIZE)
                if not resp:
                    raise SystemExit()
                nrecv += len(resp)
            n -= 1

    TIMES = args.times
    N = args.workers
    NMESSAGES = args.num
    start = time.time()
    for _ in range(TIMES):
        with ProcessPoolExecutor(max_workers=N) as e:
            for _ in range(N):
                e.submit(run_test, NMESSAGES)
    end = time.time()
    duration = end-start
    print(NMESSAGES*N*TIMES,'in', duration)
    print(NMESSAGES*N*TIMES/duration, 'requests/sec')
