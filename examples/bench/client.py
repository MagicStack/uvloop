# Copied with minimal modifications from curio
# https://github.com/dabeaz/curio

from concurrent.futures import ProcessPoolExecutor

from socket import *
import time
import sys

if len(sys.argv) > 1:
    MSGSIZE = int(sys.argv[1])
else:
    MSGSIZE = 1000

msg = b'x'*MSGSIZE

def run_test(n):
    print('Sending', NMESSAGES, 'messages')
    sock = socket(AF_INET, SOCK_STREAM)
    sock.connect(('localhost', 25000))
    while n > 0:
        sock.sendall(msg)
        nrecv = 0
        while nrecv < MSGSIZE:
            resp = sock.recv(MSGSIZE)
            if not resp:
                raise SystemExit()
            nrecv += len(resp)
        n -= 1

N = 3
NMESSAGES = 200000
start = time.time()
with ProcessPoolExecutor(max_workers=N) as e:
    for _ in range(N):
        e.submit(run_test, NMESSAGES)
end = time.time()
duration = end-start
print(NMESSAGES*N,'in', duration)
print(NMESSAGES*N/duration, 'requests/sec')
