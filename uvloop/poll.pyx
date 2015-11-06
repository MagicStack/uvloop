cdef class UVPoll(UVHandle):
    def __cinit__(self, Loop loop, int fd):
        cdef int err

        self.handle = <uv.uv_handle_t*> \
                            PyMem_Malloc(sizeof(uv.uv_poll_t))
        if self.handle is NULL:
            raise MemoryError()

        self.handle.data = <void*> self

        err = uv.uv_poll_init(loop.loop, <uv.uv_poll_t *>self.handle, fd)
        if err < 0:
            raise UVError.from_error(err)

        self.fd = fd
        self.reading_handle = None
        self.writing_handle = None

    cdef inline _poll_start(self, int flags):
        cdef int err

        err = uv.uv_poll_start(
            <uv.uv_poll_t*>self.handle,
            flags,
            __on_poll_event)

        if err < 0:
            raise UVError.from_error(err)

    cdef inline _poll_stop(self):
        cdef int err

        err = uv.uv_poll_stop(<uv.uv_poll_t*>self.handle)
        if err < 0:
            raise UVError.from_error(err)

    cdef start_reading(self, object callback):
        cdef:
            int mask = 0

        if self.reading_handle is None:
            # not reading right now, setup the handle

            mask = uv.UV_READABLE
            if self.writing_handle is not None:
                # are we writing right now?
                mask |= uv.UV_WRITABLE

            self._poll_start(mask)

        else:
            self.reading_handle._cancel()

        self.reading_handle = Handle(self.loop, callback)

    cdef start_writing(self, object callback):
        cdef:
            int mask = 0

        if self.writing_handle is None:
            # not writing right now, setup the handle

            mask = uv.UV_WRITABLE
            if self.reading_handle is not None:
                # are we reading right now?
                mask |= uv.UV_READABLE

            self._poll_start(mask)

        else:
            self.writing_handle._cancel()

        self.writing_handle = Handle(self.loop, callback)

    cdef stop_reading(self):
        if self.reading_handle is None:
            return False

        self.reading_handle._cancel()
        self.reading_handle = None

        if self.writing_handle is None:
            self.stop()
        else:
            self._poll_start(uv.UV_WRITABLE)

        return True

    cdef stop_writing(self):
        if self.writing_handle is None:
            return False

        self.writing_handle._cancel()
        self.writing_handle = None

        if self.reading_handle is None:
            self.stop()
        else:
            self._poll_start(uv.UV_READABLE)

        return True

    cdef stop(self):
        self.loop._untrack_handle(<UVHandle>self)

        if self.reading_handle is not None:
            self.reading_handle._cancel()
            self.reading_handle = None

        if self.writing_handle is not None:
            self.writing_handle._cancel()
            self.writing_handle = None

        self._poll_stop()


cdef void __on_poll_event(uv.uv_poll_t* handle,
                          int status, int events) with gil:

    cdef:
        UVPoll poll = <UVPoll> handle.data

    if status < 0:
        exc = UVError.from_error(status)
        poll.loop._handle_uvcb_exception(exc)
        return

    if events | uv.UV_READABLE and poll.reading_handle is not None:
        try:
            poll.reading_handle._run()
        except BaseException as ex:
            poll.loop._handle_uvcb_exception(ex)

    if events | uv.UV_WRITABLE and poll.writing_handle is not None:
        try:
            poll.writing_handle._run()
        except BaseException as ex:
            poll.loop._handle_uvcb_exception(ex)
