import uvloop
import asyncio


async def main():
    loop = asyncio.get_running_loop()
    call_ts = loop.time() + 1
    timer = loop.call_at(call_ts, lambda: None) # call any function
    await asyncio.sleep(1.1)
    assert timer.when() == call_ts

uvloop.install()
asyncio.run(main(), debug=True)
