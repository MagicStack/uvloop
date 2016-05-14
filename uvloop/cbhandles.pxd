cdef class Handle:
    cdef:
        Loop loop
        bint cancelled

        str meth_name
        int cb_type
        void *callback
        object arg1, arg2, arg3, arg4

        object __weakref__

    cdef inline _set_loop(self, Loop loop)
    cdef inline _run(self)
    cdef _cancel(self)


cdef class TimerHandle:
    cdef:
        object callback, args
        bint closed
        UVTimer timer
        Loop loop
        object __weakref__

    cdef _run(self)
    cdef _cancel(self)
