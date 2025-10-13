import asyncio
import ssl
from socket import AddressFamily, SocketKind, _Address, _RetAddress, socket
from typing import (
    IO,
    Any,
    Awaitable,
    Callable,
    Generator,
    Sequence,
    TypeVar,
    overload,
)

_T = TypeVar('_T')
_Context = dict[str, Any]
_ExceptionHandler = Callable[[asyncio.AbstractEventLoop, _Context], Any]
_SSLContext = bool | None | ssl.SSLContext
_ProtocolT = TypeVar("_ProtocolT", bound=asyncio.BaseProtocol)

class Loop:
    def call_soon(
        self, callback: Callable[..., Any], *args: Any, context: Any | None = ...
    ) -> asyncio.Handle: ...
    def call_soon_threadsafe(
        self, callback: Callable[..., Any], *args: Any, context: Any | None = ...
    ) -> asyncio.Handle: ...
    def call_later(
        self, delay: float, callback: Callable[..., Any], *args: Any, context: Any | None = ...
    ) -> asyncio.TimerHandle: ...
    def call_at(
        self, when: float, callback: Callable[..., Any], *args: Any, context: Any | None = ...
    ) -> asyncio.TimerHandle: ...
    def time(self) -> float: ...
    def stop(self) -> None: ...
    def run_forever(self) -> None: ...
    def close(self) -> None: ...
    def get_debug(self) -> bool: ...
    def set_debug(self, enabled: bool) -> None: ...
    def is_running(self) -> bool: ...
    def is_closed(self) -> bool: ...
    def create_future(self) -> asyncio.Future[Any]: ...
    def create_task(
        self,
        coro: Awaitable[_T] | Generator[Any, None, _T],
        *,
        name: str | None = ...,
    ) -> asyncio.Task[_T]: ...
    def set_task_factory(
        self,
        factory: Callable[[asyncio.AbstractEventLoop, Generator[Any, None, _T]], asyncio.Future[_T]] | None,
    ) -> None: ...
    def get_task_factory(
        self,
    ) -> Callable[[asyncio.AbstractEventLoop, Generator[Any, None, _T]], asyncio.Future[_T]] | None: ...
    @overload
    def run_until_complete(self, future: Generator[Any, None, _T]) -> _T: ...
    @overload
    def run_until_complete(self, future: Awaitable[_T]) -> _T: ...
    async def getaddrinfo(
        self,
        host: str | bytes | None,
        port: str | bytes | int | None,
        *,
        family: int = ...,
        type: int = ...,
        proto: int = ...,
        flags: int = ...,
    ) -> list[
        tuple[
            AddressFamily,
            SocketKind,
            int,
            str,
            tuple[str, int] | tuple[str, int, int, int],
        ]
    ]: ...
    async def getnameinfo(
        self,
        sockaddr: tuple[str, int] | tuple[str, int, int] | tuple[str, int, int, int],
        flags: int = ...,
    ) -> tuple[str, str]: ...
    async def start_tls(
        self,
        transport: asyncio.BaseTransport,
        protocol: asyncio.BaseProtocol,
        sslcontext: ssl.SSLContext,
        *,
        server_side: bool = ...,
        server_hostname: str | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
    ) -> asyncio.BaseTransport: ...
    @overload
    async def create_server(
        self,
        protocol_factory: asyncio.events._ProtocolFactory,
        host: str | Sequence[str] | None = ...,
        port: int = ...,
        *,
        family: int = ...,
        flags: int = ...,
        sock: None = ...,
        backlog: int = ...,
        ssl: _SSLContext = ...,
        reuse_address: bool | None = ...,
        reuse_port: bool | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
        start_serving: bool = ...,
    ) -> asyncio.AbstractServer: ...
    @overload
    async def create_server(
        self,
        protocol_factory: asyncio.events._ProtocolFactory,
        host: None = ...,
        port: None = ...,
        *,
        family: int = ...,
        flags: int = ...,
        sock: socket = ...,
        backlog: int = ...,
        ssl: _SSLContext = ...,
        reuse_address: bool | None = ...,
        reuse_port: bool | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
        start_serving: bool = ...,
    ) -> asyncio.AbstractServer: ...
    @overload
    async def create_connection(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        host: str = ...,
        port: int = ...,
        *,
        ssl: _SSLContext = ...,
        family: int = ...,
        proto: int = ...,
        flags: int = ...,
        sock: None = ...,
        local_addr: tuple[str, int] | None = ...,
        server_hostname: str | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    @overload
    async def create_connection(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        host: None = ...,
        port: None = ...,
        *,
        ssl: _SSLContext = ...,
        family: int = ...,
        proto: int = ...,
        flags: int = ...,
        sock: socket,
        local_addr: None = ...,
        server_hostname: str | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def create_unix_server(
        self,
        protocol_factory: asyncio.events._ProtocolFactory,
        path: str | None = ...,
        *,
        backlog: int = ...,
        sock: socket | None = ...,
        ssl: _SSLContext = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
        start_serving: bool = ...,
    ) -> asyncio.AbstractServer: ...
    async def create_unix_connection(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        path: str | None = ...,
        *,
        ssl: _SSLContext = ...,
        sock: socket | None = ...,
        server_hostname: str | None = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    def default_exception_handler(self, context: _Context) -> None: ...
    def get_exception_handler(self) -> _ExceptionHandler | None: ...
    def set_exception_handler(self, handler: _ExceptionHandler | None) -> None: ...
    def call_exception_handler(self, context: _Context) -> None: ...
    def add_reader(self, fd: Any, callback: Callable[..., Any], *args: Any) -> None: ...
    def remove_reader(self, fd: Any) -> None: ...
    def add_writer(self, fd: Any, callback: Callable[..., Any], *args: Any) -> None: ...
    def remove_writer(self, fd: Any) -> None: ...
    async def sock_recv(self, sock: socket, nbytes: int) -> bytes: ...
    async def sock_recv_into(self, sock: socket, buf: bytearray) -> int: ...
    async def sock_sendall(self, sock: socket, data: bytes) -> None: ...
    async def sock_accept(self, sock: socket) -> tuple[socket, _RetAddress]: ...
    async def sock_connect(self, sock: socket, address: _Address) -> None: ...
    async def sock_recvfrom(self, sock: socket, bufsize: int) -> bytes: ...
    async def sock_recvfrom_into(self, sock: socket, buf: bytearray, nbytes: int = ...) -> int: ...
    async def sock_sendto(self, sock: socket, data: bytes, address: _Address) -> None: ...
    async def connect_accepted_socket(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        sock: socket,
        *,
        ssl: _SSLContext = ...,
        ssl_handshake_timeout: float | None = ...,
        ssl_shutdown_timeout: float | None = ...,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def run_in_executor(
        self, executor: Any, func: Callable[..., _T], *args: Any
    ) -> _T: ...
    def set_default_executor(self, executor: Any) -> None: ...
    async def subprocess_shell(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        cmd: bytes | str,
        *,
        stdin: Any = ...,
        stdout: Any = ...,
        stderr: Any = ...,
        **kwargs: Any,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def subprocess_exec(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        *args: Any,
        stdin: Any = ...,
        stdout: Any = ...,
        stderr: Any = ...,
        **kwargs: Any,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def connect_read_pipe(
        self, protocol_factory: Callable[[], _ProtocolT], pipe: Any
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def connect_write_pipe(
        self, protocol_factory: Callable[[], _ProtocolT], pipe: Any
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    def add_signal_handler(
        self, sig: int, callback: Callable[..., Any], *args: Any
    ) -> None: ...
    def remove_signal_handler(self, sig: int) -> bool: ...
    async def create_datagram_endpoint(
        self,
        protocol_factory: Callable[[], _ProtocolT],
        local_addr: tuple[str, int] | None = ...,
        remote_addr: tuple[str, int] | None = ...,
        *,
        family: int = ...,
        proto: int = ...,
        flags: int = ...,
        reuse_address: bool | None = ...,
        reuse_port: bool | None = ...,
        allow_broadcast: bool | None = ...,
        sock: socket | None = ...,
    ) -> tuple[asyncio.BaseProtocol, _ProtocolT]: ...
    async def shutdown_asyncgens(self) -> None: ...
    async def shutdown_default_executor(
        self,
        timeout: float | None = ...,
    ) -> None: ...
    # Loop doesn't implement these, but since they are marked as abstract in typeshed,
    # we have to put them in so mypy thinks the base methods are overridden
    async def sendfile(
        self,
        transport: asyncio.BaseTransport,
        file: IO[bytes],
        offset: int = ...,
        count: int | None = ...,
        *,
        fallback: bool = ...,
    ) -> int: ...
    async def sock_sendfile(
        self,
        sock: socket,
        file: IO[bytes],
        offset: int = ...,
        count: int | None = ...,
        *,
        fallback: bool = ...
    ) -> int: ...
