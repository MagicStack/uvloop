cdef extern from "Python.h":
    int PY_VERSION_HEX

    void* PyMem_RawMalloc(size_t n)
    void* PyMem_RawRealloc(void *p, size_t n)
    void* PyMem_RawCalloc(size_t nelem, size_t elsize)
    void PyMem_RawFree(void *p)

    object PyUnicode_EncodeFSDefault(object)
    void PyErr_SetInterrupt() nogil

    void PyOS_AfterFork()
    void _PyImport_AcquireLock()
    int _PyImport_ReleaseLock()
    void _Py_RestoreSignals()

    object PyMemoryView_FromMemory(char *mem, ssize_t size, int flags)
    object PyMemoryView_FromObject(object obj)
    int PyMemoryView_Check(object obj)

    cdef enum:
        PyBUF_WRITE


cdef extern from "includes/compat.h":
    ctypedef struct PyContext
    PyContext* PyContext_CopyCurrent() except NULL
    int PyContext_Enter(PyContext *) except -1
    int PyContext_Exit(PyContext *) except -1
