ctypedef enum traces:
    TRACE_TASK_CREATED,
    TRACE_DNS_REQUEST_BEGIN,
    TRACE_DNS_REQUEST_END

cdef class TracingCollector:
    cpdef dns_request_begin(self, object host, object port, object family,
                            object type, object proto, object flags)
    cpdef dns_request_end(self, object result)
    cpdef task_created(self, object task)

cdef __send_trace(traces trace, object arg1=*, object arg2=*, object arg3=*,
                  object arg4=*, object arg5=*, object arg6=*)
