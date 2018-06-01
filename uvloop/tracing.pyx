from collections import deque
from contextlib import contextmanager


cdef class TracingCollector:
    cpdef dns_request_begin(self, host, port, family, type, proto, flags):
        """Called when a DNS request starts"""

    cpdef dns_request_end(self, result):
        """Called when a DNS request finishes, result can contain either
        the response when finished successfully or an exception if it finished
        with an error"""

    cpdef task_created(self, task):
        """Called when a new task is created"""


if PY37:
    import contextvars

    __collectors = contextvars.ContextVar('__collectors', default=None)

    @contextmanager
    def tracing(collector):
        if not isinstance(collector, TracingCollector):
            raise ValueError(
                "collector must be a TracingCollector class instance")

        collectors = __collectors.get(None)
        if collectors is None:
            collectors = list()
            __collectors.set(collectors)
        collectors.append(collector)
        yield
        collectors.pop()
        if not collectors:
            __collectors.set(None)
else:
    @contextmanager
    def tracing(*args, **kwargs):
        raise NotImplementedError(
            "tracing only supported by Python 3.7 or newer versions")


cdef inline __send_trace(traces trace, arg1=None, arg2=None, arg3=None,
                         arg4=None, arg5=None, arg6=None):
    cdef:
        PyObject* collectors = NULL

    if not PY37:
        return

    PyContextVar_Get(<PyContextVar*> __collectors, None, &collectors)
    if <object>collectors is not None:
        for collector in <list>collectors:
            try:
                if trace == TRACE_TASK_CREATED:
                    (<TracingCollector>collector).task_created(arg1)
                elif trace == TRACE_DNS_REQUEST_BEGIN:
                    (<TracingCollector>collector).dns_request_begin(arg1, arg2,
                                                                    arg3, arg4,
                                                                    arg5, arg6)
                elif trace == TRACE_DNS_REQUEST_END:
                    (<TracingCollector>collector).dns_request_end(arg1)
            except Exception as exc:
                aio_logger.error(
                    'trace finished with an exception %r',
                    exc)
