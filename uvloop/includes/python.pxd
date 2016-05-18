cdef extern from "Python.h":
    void* PyMem_Malloc(size_t n)
    void* PyMem_Realloc(void *p, size_t n)
    void* PyMem_Calloc(size_t nelem, size_t elsize)  # Python >= 3.5!
    void PyMem_Free(void *p)

    object PyUnicode_EncodeFSDefault(object)
    void PyErr_SetInterrupt() nogil
