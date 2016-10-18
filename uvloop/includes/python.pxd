cdef extern from "Python.h":
    void* PyMem_RawMalloc(size_t n)
    void* PyMem_RawRealloc(void *p, size_t n)
    void* PyMem_RawCalloc(size_t nelem, size_t elsize)  # Python >= 3.5!
    void PyMem_RawFree(void *p)

    object PyUnicode_EncodeFSDefault(object)
    void PyErr_SetInterrupt() nogil

    void PyOS_AfterFork()
    void _PyImport_AcquireLock()
    int _PyImport_ReleaseLock()
    void _Py_RestoreSignals()
