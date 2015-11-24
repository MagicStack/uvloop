@cython.internal
cdef class UVRequest:
    """A base class for all libuv requests (uv_getaddrinfo_t, etc).

    Important: it's a responsibility of the subclass to call the
    "on_done" method in the request's callback.
    """

    def __cinit__(self, Loop loop, *_):
        self.loop = loop
        self.done = 0
        loop.__track_request__(self)

    def __dealloc__(self):
        if self.request is not NULL:
            if self.done == 0:
                raise RuntimeError(
                    'Unable to deallocate request for {!r} (not done)'
                    .format(self))
            PyMem_Free(self.request)
            self.request = NULL

    cdef on_done(self):
        self.done = 1
        self.loop.__untrack_request__(self)

    cdef void cancel(self):
        cdef int err

        if self.done == 1:
            return

        IF DEBUG:
            if self.request is NULL:
                raise RuntimeError(
                    '{}.cancel: .request is NULL'.format(
                        self.__class__.__name__))

            if self.request.data is NULL:
                raise RuntimeError(
                    '{}.cancel: .request.data is NULL'.format(
                        self.__class__.__name__))

            if <UVRequest>self.request.data is not self:
                raise RuntimeError(
                    '{}.cancel: .request.data is not UVRequest'.format(
                        self.__class__.__name__))

        # We only can cancel pending requests.  Let's try.
        err = uv.uv_cancel(self.request)
        if err < 0:
            if err == uv.UV_EBUSY:
                # Can't close the request -- it's executing.
                pass
            elif err == uv.UV_EINVAL:
                # From libuv docs:
                #
                #     Only cancellation of uv_fs_t, uv_getaddrinfo_t,
                #     uv_getnameinfo_t and uv_work_t requests is currently
                #     supported.
                self.on_done()
                return
            else:
                ex = convert_error(err)
                self.loop._handle_uvcb_exception(ex)
