import uvloop, uvloop.const
uvloop.install()
import asyncio

print(f'{uvloop.const.FS_EVENT_CHANGE}')

def shutdown():
    asyncio.get_running_loop().stop()
    
event_count = 0

def cb(pth, events):
    global h, event_count
    print(f'{pth} {events}')
    event_count += 1
    if event_count == 4:
        h.stop()
        asyncio.get_running_loop().call_later(4, shutdown)

loop = asyncio.get_event_loop()
h = loop.monitor_fs('/tmp/f.txt', cb, 0)

loop.run_forever()
