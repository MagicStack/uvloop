cdef class TracingCollector:
    cpdef dns_request_begin(self, object arg1, object arg2, object arg3,
                           object arg4, object arg5, object arg6)
    cpdef dns_request_end(self, object arg1)
    cpdef task_created(self, object arg1)

cdef __trace_dns_request_end(object arg1)
cdef __trace_dns_request_begin(object arg1, object arg2, object arg3,
                               object arg4, object arg5, object arg6)
cdef __trace_task_created(object arg1)
