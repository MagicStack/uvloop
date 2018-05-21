import contextvars
from contextlib import contextmanager


__tracing_ctx = contextvars.ContextVar('__tracing_ctx')


cdef class TracingCollector:
    cpdef dns_request_begin(self, arg1, arg2, arg3, arg4, arg5, arg6):
        pass

    cpdef dns_request_end(self, arg1):
        pass

    cpdef task_created(self, arg1):
        pass


@contextmanager
def tracing(collector):
    if not isinstance(collector, TracingCollector):
        raise ValueError("collector must be a TracingCollector class instance")

    __tracing_ctx.set(collector)
    yield
    __tracing_ctx.set(None)


cdef inline __trace_dns_request_end(arg1):
    cdef TracingCollector collector = __tracing_ctx.get(None)
    if collector:
        collector.dns_request_end(arg1)


cdef inline __trace_dns_request_begin(arg1, arg2, arg3, arg4, arg5, arg6):
    cdef TracingCollector collector = __tracing_ctx.get(None)
    if collector:
        collector.dns_request_begin(arg1, arg2, arg3, arg4, arg5, arg6)

cdef inline __trace_task_created(arg1):
    cdef TracingCollector collector = __tracing_ctx.get(None)
    if collector:
        collector.task_created(arg1)
