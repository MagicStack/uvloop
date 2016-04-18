from posix.signal cimport sigaction_t, sigaction, sigfillset
from libc.signal cimport SIG_DFL, SIG_IGN, sighandler_t, signal, SIGINT


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
            sigaction_t sa

        if not self.saved:
            raise RuntimeError("SignalsStack.save() wasn't called")

        for i in range(MAX_SIG):
            if self.signals[i] == NULL:
                continue

            memset(&sa, 0, sizeof(sa))
            if sigfillset(&sa.sa_mask):
                raise RuntimeError(
                    'failed to restore signal (sigfillset failed)')
            sa.sa_handler = self.signals[i]
            if sigaction(i, &sa, NULL):
                raise convert_error(-errno.errno)


cdef void __signal_handler_sigint(int sig) nogil:
    cdef sighandler_t handle

    # We can run this method without GIL because there is no
    # Python code here -- all '.' and '[]' operators work on
    # C structs/pointers.

    if sig != SIGINT or __main_loop__ is None:
        return

    if __main_loop__._executing_py_code and not __main_loop__._custom_sigint:
        PyErr_SetInterrupt()  # void
        return

    if __main_loop__.uv_signals is not None:
        handle = __main_loop__.uv_signals.signals[sig]
        if handle is not NULL:
            handle(sig)  # void


cdef __signal_set_sigint():
    cdef sigaction_t sa
    memset(&sa, 0, sizeof(sa))
    if sigfillset(&sa.sa_mask):
        raise RuntimeError(
            'failed to set SIGINT signal (sigfillset failed)')
    sa.sa_handler = __signal_handler_sigint
    if sigaction(SIGINT, &sa, NULL):
        raise convert_error(-errno.errno)
