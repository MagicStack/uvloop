cdef class Handle:
    cdef:
        object callback, args
        bint cancelled
        bint done
        Loop loop
        object __weakref__

    cdef inline _run(self)
    cdef _cancel(self)


cdef class TimerHandle:
    cdef:
        object callback, args
        bint closed
        UVTimer timer
        Loop loop
        object __weakref__

    cdef _cancel(self)
