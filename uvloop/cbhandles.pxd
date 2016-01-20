cdef class Handle:
    cdef:
        bint cancelled
        bint done
        Loop loop

        int cb_type
        void *callback
        object arg1, arg2, arg3

        object __weakref__

    cdef _run(self)
    cdef _cancel(self)

    @staticmethod
    cdef new(Loop loop, object callback, object args)

    @staticmethod
    cdef new_meth(Loop loop, method_t *callback, object ctx)

    @staticmethod
    cdef new_meth1(Loop loop, method1_t *callback,
                   object ctx, object arg)

    @staticmethod
    cdef new_meth2(Loop loop, method2_t *callback,
                   object ctx, object arg1, object arg2)

cdef class TimerHandle:
    cdef:
        object callback, args
        bint closed
        UVTimer timer
        Loop loop
        object __weakref__

    cdef _run(self)
    cdef _cancel(self)
