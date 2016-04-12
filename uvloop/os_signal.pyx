from posix.signal cimport sigaction_t, sigaction
from libc.signal cimport SIG_DFL, SIG_IGN, SIG_ERR, sighandler_t, signal, SIGINT


cdef class SignalsStack:
    def __cinit__(self):
        self.saved = 0
        for i in range(MAX_SIG):
            self.signals[i] = NULL

    cdef save(self):
        cdef sigaction_t sa

        for i in range(MAX_SIG):
            if sigaction(i, NULL, &sa) == -1 or sa.sa_handler is NULL:
                continue

            self.signals[i] = <sighandler_t>sa.sa_handler

        self.saved = 1

    cdef restore(self):
        cdef:
            sighandler_t sig

        if not self.saved:
            raise RuntimeError("SignalsStack.save() wasn't called")

        for i in range(MAX_SIG):
            if self.signals[i] == NULL:
                continue
            sig = signal(i, self.signals[i])
            if sig == SIG_ERR:
                raise RuntimeError("Couldn't restore signal {}".format(i))


cdef void __signal_handler_sigint(int sig) nogil:
    cdef sighandler_t handle

    if sig != SIGINT:
        return

    if __main_loop__ is None or __main_loop__.py_signals is None:
        # Shouldn't ever happen.
        return

    if __main_loop__._executing_py_code and not __main_loop__._custom_sigint:
        handle = __main_loop__.py_signals.signals[sig]
        if handle not in (SIG_DFL, SIG_IGN, SIG_ERR, NULL):
            handle(sig)  # void
            return

    if __main_loop__.uv_signals is not None:
        handle = __main_loop__.uv_signals.signals[sig]
        if handle not in (SIG_DFL, SIG_IGN, SIG_ERR, NULL):
            handle(sig)  # void


cdef void __signal_set_sigint():
    signal(SIGINT, <sighandler_t>__signal_handler_sigint)
