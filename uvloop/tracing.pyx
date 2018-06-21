from contextlib import contextmanager

if PY37:
    import contextvars
    __traced_ctx = contextvars.ContextVar('__traced_ctx', default=None)
else:
    __traced_ctx = None


cdef class TracedContext:
    def __cinit__(self, tracer, root_span):
        self._tracer = tracer
        self._root_span = root_span
        self._span = None

    cdef object start_span(self, name, tags=None):
        parent_span = self._span if self._span else self._root_span
        span = self._tracer.start_span(name, parent_span)

        if tags:
            for key, value in tags.items():
                span.set_tag(key, value)

        self._span = span
        return self._span

    cdef object current_span(self):
        return self._span


cdef inline TracedContext __traced_context():
    cdef:
        PyObject* traced_context = NULL

    if not PY37:
        return

    PyContextVar_Get(<PyContextVar*> __traced_ctx, None, &traced_context)

    if <object>traced_context is None:
        return
    return <TracedContext>traced_context


def start_tracing(tracer, root_span):
    if not PY37:
        raise RuntimeError(
            "tracing only supported by Python 3.7 or newer versions")

    traced_context = __traced_ctx.get(None)
    if traced_context is not None:
        raise RuntimeError("Tracing already started")

    traced_context = TracedContext(tracer, root_span)
    __traced_ctx.set(traced_context)


def stop_tracing():
    if not PY37:
        raise RuntimeError(
            "tracing only supported by Python 3.7 or newer versions")

    traced_context = __traced_context()
    if traced_context is None:
        return

    span = traced_context.current_span()
    if span and not span.is_finished:
        span.finish()

    __traced_ctx.set(None)
