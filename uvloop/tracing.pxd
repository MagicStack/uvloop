cdef class TracedContext:
    cdef:
        object _tracer
        object _span
        object _root_span

    cdef object start_span(self, name, tags=?)
    cdef object current_span(self)

cdef TracedContext __traced_context()
