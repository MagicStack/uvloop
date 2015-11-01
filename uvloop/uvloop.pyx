cimport clibuv

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef class UVLoop:
    cdef:
        clibuv.uv_loop_t *loop

    def __cinit__(self):
        self.loop = <clibuv.uv_loop_t*> PyMem_Malloc(sizeof(clibuv.uv_loop_t))
        self.loop.data = <void*> self

        clibuv.uv_loop_init(self.loop)

        print(clibuv.uv_now(self.loop))

    def __dealloc__(self):
        PyMem_Free(self.loop)
