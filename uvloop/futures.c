#include "Python.h"
#include "structmember.h"

static struct Locals { // XXX!!!
    PyObject* is_error;
    PyObject* ce_error;
} locals;

typedef enum {
    STATE_PENDING,
    STATE_CANCELLED,
    STATE_FINISHED
} fut_state;

typedef struct {
    PyObject_HEAD
    PyObject *fut_loop;
    PyObject *fut_callbacks;
    PyObject *fut_exception;
    PyObject *fut_result;
    fut_state fut_state;
    int fut_log_tb;
    int fut_blocking;
    PyObject *fut_weakreflist;
} FutureObj;

static PyObject *
_schedule_callbacks(FutureObj *fut) {
    if (fut->fut_callbacks == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "NULL callbacks");
        return NULL;
    }

    Py_ssize_t len = PyList_GET_SIZE(fut->fut_callbacks);

    if (len == 0) {
        Py_RETURN_NONE;
    }

    PyObject* iters = PyList_GetSlice(fut->fut_callbacks, 0, len);
    if (iters == NULL) {
        return NULL;
    }

    if (PyList_SetSlice(fut->fut_callbacks, 0, len, NULL) < 0) {
        Py_DECREF(iters);
        return NULL;
    }

    for (int i = 0; i < len; i++) {
        PyObject *cb = PyList_GET_ITEM(iters, i);

        if (PyObject_CallMethod(
            fut->fut_loop, "call_soon", "OO", cb, fut, NULL) == NULL)
        {
            Py_DECREF(fut->fut_callbacks);
            return NULL;
        }
    }

    Py_DECREF(iters);
    Py_RETURN_NONE;
}

static PyObject *
FutureObj_new(PyTypeObject *type, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = {"loop", NULL};

    PyObject *loop;
    FutureObj *fut;

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|O", kwlist, &loop))
        return NULL;

    fut = PyObject_GC_New(FutureObj, type);
    if (fut == NULL)
        return NULL;

    fut->fut_callbacks = PyList_New(0);
    if (fut->fut_callbacks == NULL)
        return NULL;

    fut->fut_weakreflist = NULL;

    fut->fut_state = STATE_PENDING;
    fut->fut_log_tb = 0;
    fut->fut_blocking = 0;
    fut->fut_exception = NULL;
    fut->fut_result = NULL;

    Py_INCREF(loop);
    fut->fut_loop = loop;
    _PyObject_GC_TRACK(fut);
    return (PyObject *)fut;
}

static void
FutureObj_dealloc(FutureObj *fut)
{
    _PyObject_GC_UNTRACK(fut);

    Py_CLEAR(fut->fut_loop);
    Py_CLEAR(fut->fut_callbacks);

    Py_CLEAR(fut->fut_result);
    Py_CLEAR(fut->fut_exception);

    if (fut->fut_weakreflist != NULL)
        PyObject_ClearWeakRefs((PyObject *)fut);

    PyObject_GC_Del(fut);
}

static int
FutureObj_traverse(FutureObj *fut, visitproc visit, void *arg)
{
    Py_VISIT((PyObject *)fut->fut_loop);
    Py_VISIT((PyObject *)fut->fut_callbacks);
    Py_VISIT((PyObject *)fut->fut_result);
    Py_VISIT((PyObject *)fut->fut_exception);
    return 0;
}

static PyObject *
FutureObj_result(FutureObj *fut, PyObject *arg) {
    if (fut->fut_state == STATE_CANCELLED) {
        PyErr_SetString(locals.ce_error, "");
        return NULL;
    }

    if (fut->fut_state != STATE_FINISHED) {
        PyErr_SetString(locals.is_error, "Result is not ready.");
        return NULL;
    }

    fut->fut_log_tb = 0;
    if (fut->fut_exception != NULL) {
        PyObject *type = NULL;
        type = PyExceptionInstance_Class(fut->fut_exception);
        PyErr_SetObject(type, fut->fut_exception);
        return NULL;
    }

    Py_INCREF(fut->fut_result);
    return fut->fut_result;
}

static PyObject *
FutureObj_exception(FutureObj *fut, PyObject *arg) {
    if (fut->fut_state == STATE_CANCELLED) {
        PyErr_SetString(locals.ce_error, "");
        return NULL;
    }

    if (fut->fut_state != STATE_FINISHED) {
        PyErr_SetString(locals.is_error, "Result is not ready.");
        return NULL;
    }

    if (fut->fut_exception != NULL) {
        Py_INCREF(fut->fut_exception);
        return fut->fut_exception;
    }

    Py_RETURN_NONE;
}

static PyObject *
FutureObj_set_result(FutureObj *fut, PyObject *res) {
    if (fut->fut_state != STATE_PENDING) {
        PyErr_SetString(locals.is_error, "invalid state");
        return NULL;
    }

    Py_INCREF(res);
    fut->fut_result = res;
    fut->fut_state = STATE_FINISHED;

    if (_schedule_callbacks(fut) == NULL) {
        return NULL;
    }

    Py_RETURN_NONE;
}

static PyObject *
FutureObj_set_exception(FutureObj *fut, PyObject *exc) {
    if (fut->fut_state != STATE_PENDING) {
        PyErr_SetString(locals.is_error, "invalid state");
        return NULL;
    }

    PyObject *exc_val = NULL;
    if (PyExceptionClass_Check(exc)) {
        exc_val = PyObject_CallObject(exc, NULL);
        if (exc_val == NULL) {
            return NULL;
        }
    }
    if (exc_val == NULL) {
        exc_val = exc;
        Py_INCREF(exc);
    }
    if (!PyExceptionInstance_Check(exc_val)) {
        Py_DECREF(exc_val);
        PyErr_SetString(PyExc_TypeError, "invalid exception object");
        return NULL;
    }

    fut->fut_exception = exc_val;
    fut->fut_state = STATE_FINISHED;

    if (_schedule_callbacks(fut) == NULL) {
        return NULL;
    }

    fut->fut_log_tb = 1;

    Py_RETURN_NONE;
}

static PyObject *
FutureObj_await(FutureObj *fut)
{
    Py_INCREF(fut);
    return (PyObject *)fut;
}

static PyObject *
FutureObj_iternext(FutureObj *fut)
{
    PyObject *res;

    if (fut->fut_state == STATE_PENDING && !fut->fut_blocking) {
        fut->fut_blocking = 1;
        Py_INCREF(fut);
        return (PyObject *)fut;
    }

    if (fut->fut_state == STATE_PENDING) {
        PyErr_Format(PyExc_RuntimeError,
                     "yield from wasn't used with future");
        return NULL;
    }

    res = FutureObj_result(fut, NULL);
    if (res == NULL) {
        // exception
        return NULL;
    }

    // normal result
    PyErr_SetObject(PyExc_StopIteration, res);
    return NULL;
}

static PyObject *
FutureObj_send(FutureObj *fut, PyObject *res) {
    PyErr_Format(PyExc_RuntimeError,
                 "future.send() was called; unpatched asyncio");
    return NULL;
}

static PyObject *
FutureObj_add_done_callback(FutureObj *fut, PyObject *arg)
{
    if (fut->fut_state != STATE_PENDING) {
        if (PyObject_CallMethod(
            fut->fut_loop, "call_soon", "OO", arg, fut->fut_loop) == NULL)
        {
            return NULL;
        }
    } else {
        int err = PyList_Append(fut->fut_callbacks, arg);
        if (err != 0) {
            return NULL;
        }
    }
    Py_RETURN_NONE;
}

static PyObject *
FutureObj_cancel(FutureObj *fut, PyObject *arg)
{
    if (fut->fut_state != STATE_PENDING) {
        Py_RETURN_FALSE;
    }
    fut->fut_state = STATE_CANCELLED;

    if (_schedule_callbacks(fut) == NULL) {
        return NULL;
    }

    Py_RETURN_TRUE;
}

static PyObject *
FutureObj_cancelled(FutureObj *fut, PyObject *arg)
{
    if (fut->fut_state == STATE_CANCELLED) {
        Py_RETURN_TRUE;
    } else {
        Py_RETURN_FALSE;
    }
}

static PyObject *
FutureObj_done(FutureObj *fut, PyObject *arg)
{
    if (fut->fut_state == STATE_PENDING) {
        Py_RETURN_FALSE;
    } else {
        Py_RETURN_TRUE;
    }
}

static PyObject *
FutureObj_get_blocking(FutureObj *fut)
{
    if (fut->fut_blocking) {
        Py_RETURN_TRUE;
    } else {
        Py_RETURN_FALSE;
    }
}

static int
FutureObj_set_blocking(FutureObj *fut, PyObject *val)
{
    if (PyObject_IsTrue(val)) {
        fut->fut_blocking = 1;
    } else {
        fut->fut_blocking = 0;
    }
    return 0;
}

static PyAsyncMethods FutureType_as_async = {
    (unaryfunc)FutureObj_await,      /* am_await */
    0,                                  /* am_aiter */
    0                                   /* am_anext */
};

static PyMethodDef FutureType_methods[] = {
    {"add_done_callback", (PyCFunction)FutureObj_add_done_callback,
                          METH_O, NULL},
    {"set_result", (PyCFunction)FutureObj_set_result, METH_O, NULL},
    {"set_exception", (PyCFunction)FutureObj_set_exception, METH_O, NULL},
    {"cancel", (PyCFunction)FutureObj_cancel, METH_NOARGS, NULL},
    {"cancelled", (PyCFunction)FutureObj_cancelled, METH_NOARGS, NULL},
    {"done", (PyCFunction)FutureObj_done, METH_NOARGS, NULL},
    {"result", (PyCFunction)FutureObj_result, METH_NOARGS, NULL},
    {"exception", (PyCFunction)FutureObj_exception, METH_NOARGS, NULL},

    {"send", (PyCFunction)FutureObj_send, METH_O, NULL}, // XXX
    {NULL, NULL}        /* Sentinel */
};

static PyGetSetDef FutureType_getsetlist[] = {
    {"_blocking", (getter)FutureObj_get_blocking,
                  (setter)FutureObj_set_blocking, NULL},
    {NULL} /* Sentinel */
};

static PyTypeObject FutureType = {
    PyVarObject_HEAD_INIT(&PyType_Type, 0)
    "Future",
    sizeof(FutureObj),                    /* tp_basicsize */
    0,                                       /* tp_itemsize */
    (destructor)FutureObj_dealloc,        /* destructor tp_dealloc */
    0,                                       /* tp_print */
    0,                                       /* tp_getattr */
    0,                                       /* tp_setattr */
    &FutureType_as_async,          /* tp_as_async */
    0,                                       /* tp_repr */
    0,                                       /* tp_as_number */
    0,                                       /* tp_as_sequence */
    0,                                       /* tp_as_mapping */
    0,                                       /* tp_hash */
    0,                                       /* tp_call */
    0,                                       /* tp_str */
    PyObject_GenericGetAttr,                 /* tp_getattro */
    0,                                       /* tp_setattro */
    0,                                       /* tp_as_buffer */
    Py_TPFLAGS_DEFAULT | Py_TPFLAGS_HAVE_GC, /* tp_flags */
    "Fast asyncio.Future implementation.",
    (traverseproc)FutureObj_traverse,     /* traverseproc tp_traverse */
    0,                                       /* tp_clear */
    0,                                       /* tp_richcompare */
    offsetof(FutureObj, fut_weakreflist),  /* tp_weaklistoffset */
    PyObject_SelfIter,                       /* tp_iter */
    (iternextfunc)FutureObj_iternext,     /* tp_iternext */
    FutureType_methods,            /* tp_methods */
    0,                                       /* tp_members */
    FutureType_getsetlist,         /* tp_getset */
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    FutureObj_new,                        /* tp_new */
    PyObject_Del,                            /* tp_free */
};


PyDoc_STRVAR(module_doc, "Fast asyncio.Future implementation.\n");


static PyObject*
ref_asyncio_attr(PyObject *module, PyObject *asyncio, const char* aname)
{
    PyObject *a = PyObject_GetAttrString(asyncio, aname);
    if (a == NULL) {
        Py_DECREF(asyncio);
        return NULL;
    } else {
        if (PyModule_AddObject(module, aname, a) < 0) {
            Py_DECREF(asyncio);
            Py_DECREF(a);
            return NULL;
        }
    }
    return a;
}

static int
futures_exec(PyObject *module) {
    Py_INCREF(&FutureType);
    if (PyModule_AddObject(module, "Future", (PyObject *)&FutureType) < 0) {
        Py_DECREF(&FutureType);
        return -1;
    }

    // XXX!!!
    PyObject *asyncio = PyImport_ImportModule("asyncio");
    if (asyncio == NULL) {
        return -1;
    }
    locals.is_error = ref_asyncio_attr(module, asyncio, "InvalidStateError");
    if (locals.is_error == NULL) {
        return -1;
    }
    locals.ce_error = ref_asyncio_attr(module, asyncio, "CancelledError");
    if (locals.ce_error == NULL) {
        return -1;
    }
    Py_DECREF(asyncio);

    return 0;
}

static PyModuleDef_Slot future_slots[] = {
    {Py_mod_exec, futures_exec},
    {0, NULL}
};

static struct PyModuleDef _futuresmodule = {
    PyModuleDef_HEAD_INIT,      /* m_base */
    "futures",                  /* m_name */
    module_doc,                 /* m_doc */
    0,                          /* m_size */
    NULL,                       /* m_methods */
    future_slots,               /* m_slots */
    NULL,                       /* m_traverse */
    NULL,                       /* m_clear */
    NULL                        /* m_free */
};

PyMODINIT_FUNC
PyInit_futures(void)
{
    return PyModuleDef_Init(&_futuresmodule);
}
