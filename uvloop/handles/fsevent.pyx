@cython.no_gc_clear
cdef class UVFSEvent(UVHandle):
    cdef _init(self, Loop loop, char* path, object callback,
               int flags):

        cdef int err

        self._start_init(loop)

        self._handle = <uv.uv_handle_t*> PyMem_RawMalloc(sizeof(uv.uv_fs_event_t))
        if self._handle is NULL:
            self._abort_init()
            raise MemoryError()

        err = uv.uv_fs_event_init(self._loop.uvloop, <uv.uv_fs_event_t*>self._handle)
        if err < 0:
            self._abort_init()
            raise convert_error(err)

        self._finish_init()

        self.callback = callback

        err = uv.uv_fs_event_start(<uv.uv_fs_event_t*>self._handle, __uvfsevent_callback, path, flags)
        if err < 0:
            self._abort_init()
            raise convert_error(err)


    cdef _stop(self):
        cdef int err

        if not self._is_alive():
            return

        err = uv.uv_fs_event_stop(<uv.uv_fs_event_t*>self._handle)
        self.closed = True
        if err < 0:
            exc = convert_error(err)
            self._fatal_error(exc, True)
            return

    def stop(self):
        self._stop()

    @staticmethod
    cdef UVFSEvent new(Loop loop, char* path, object callback,
               int flags):

        cdef UVFSEvent handle
        handle = UVFSEvent.__new__(UVFSEvent)
        handle._init(loop, path, callback, flags)
        return handle


cdef void __uvfsevent_callback(uv.uv_fs_event_t* handle, const char *filename,
                               int events, int status) with gil:
    if __ensure_handle_data(<uv.uv_handle_t*>handle, "UVFSEvent callback") == 0:
        return

    cdef:
        UVFSEvent fs_event = <UVFSEvent> handle.data

    try:
        fs_event.callback(filename, events)
    except BaseException as ex:
        fs_event._error(ex, False)
