from cpython.pycapsule cimport PyCapsule_GetPointer


def capsule_equals(cap1, cap2):
    return PyCapsule_GetPointer(cap1, NULL) == PyCapsule_GetPointer(cap2, NULL)
