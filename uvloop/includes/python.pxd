cdef extern from "Python.h":
    int PY_VERSION_HEX

    void* PyMem_RawMalloc(size_t n)
    void* PyMem_RawRealloc(void *p, size_t n)
    void* PyMem_RawCalloc(size_t nelem, size_t elsize)
    void PyMem_RawFree(void *p)

    object PyUnicode_EncodeFSDefault(object)
    void PyErr_SetInterrupt() nogil

    void _Py_RestoreSignals()


cdef extern from "includes/compat.h":
    ctypedef struct PyContext
    PyContext* PyContext_CopyCurrent() except NULL
    int PyContext_Enter(PyContext *) except -1
    int PyContext_Exit(PyContext *) except -1

    object Context_CopyCurrent()
    int Context_Enter(object) except -1
    int Context_Exit(object) except -1

    void PyOS_BeforeFork()
    void PyOS_AfterFork_Parent()
    void PyOS_AfterFork_Child()
