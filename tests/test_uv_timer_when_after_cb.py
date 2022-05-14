import uvloop
import asyncio


async def main():
    loop = asyncio.get_running_loop()
    now = loop.time()
    timer = loop.call_later(1, lambda: None) # call any function
    await asyncio.sleep(1.1)
    assert timer.when() == now + 1

uvloop.install()
asyncio.run(main(), debug=True)
