import uvloop
import asyncio


async def main():
    loop = asyncio.get_running_loop()
    timer = loop.call_later(0.1, lambda: None) # call any function
    await asyncio.sleep(0.2)
    timer.when()

uvloop.install()
asyncio.run(main(), debug=True)
