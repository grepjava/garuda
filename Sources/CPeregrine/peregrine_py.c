/* Python.h insists on being included before anything else. Our own header is
 * included afterwards and deliberately does NOT include Python.h -- see the
 * comment at the top of peregrine_py.h. */
#define PY_SSIZE_T_CLEAN 1
#include <Python.h>

#include "peregrine_py.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

/* The header mirrors three CPython types. Prove the mirrors are exact. */
_Static_assert(sizeof(pg_ssize_t) == sizeof(Py_ssize_t), "Py_ssize_t mirror");
_Static_assert(sizeof(pg_type_slot) == sizeof(PyType_Slot), "PyType_Slot mirror");
_Static_assert(offsetof(pg_type_slot, pfunc) == offsetof(PyType_Slot, pfunc),
               "PyType_Slot layout");
_Static_assert(sizeof(pg_method_def) == sizeof(PyMethodDef), "PyMethodDef mirror");
_Static_assert(offsetof(pg_method_def, ml_flags) == offsetof(PyMethodDef, ml_flags),
               "PyMethodDef layout");

/* ======================================================================== */
/* Interpreter lifecycle                                                    */
/* ======================================================================== */

int pg_py_init(const char *program, const char *pyhome, int isolated) {
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    /* Signals belong to the poller loop, not to Python: an app that blocks in C
     * must not swallow SIGTERM, and our handler is the one that drains the
     * accept queue cleanly. */
    config.install_signal_handlers = 0;
    config.parse_argv = 0;
    config.isolated = isolated ? 1 : 0;

    PyStatus st;
    if (program && program[0]) {
        st = PyConfig_SetBytesString(&config, &config.program_name, program);
        if (PyStatus_Exception(st)) { PyConfig_Clear(&config); return -1; }
    }
    if (pyhome && pyhome[0]) {
        st = PyConfig_SetBytesString(&config, &config.home, pyhome);
        if (PyStatus_Exception(st)) { PyConfig_Clear(&config); return -1; }
    }

    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) return -1;
    return 0;
}

void pg_py_finalize(void) {
    if (Py_IsInitialized()) Py_FinalizeEx();
}

int pg_py_is_initialized(void) { return Py_IsInitialized(); }

int pg_py_add_syspath(const char *dir) {
    PyObject *path = PySys_GetObject("path");   /* borrowed */
    if (!path) return -1;
    PyObject *s = PyUnicode_DecodeFSDefault(dir);
    if (!s) return -1;
    /* Prepend: the application directory must win over site-packages. */
    int rc = PyList_Insert(path, 0, s);
    Py_DECREF(s);
    return rc;
}

PyObject *pg_py_import(const char *name) { return PyImport_ImportModule(name); }

PyObject *pg_py_exec_module(const char *name, const char *src) {
    PyObject *mod = PyImport_AddModule(name);   /* borrowed */
    if (!mod) return NULL;
    PyObject *dict = PyModule_GetDict(mod);     /* borrowed */
    if (PyDict_GetItemString(dict, "__builtins__") == NULL) {
        PyObject *builtins = PyEval_GetBuiltins();  /* borrowed */
        if (PyDict_SetItemString(dict, "__builtins__", builtins) != 0) return NULL;
    }
    PyObject *res = PyRun_String(src, Py_file_input, dict, dict);
    if (!res) return NULL;
    Py_DECREF(res);
    Py_INCREF(mod);
    return mod;
}

int pg_py_version_hex(void) { return (int)PY_VERSION_HEX; }

/* The version of the libpython actually linked, read at runtime.
 *
 * PY_VERSION_HEX above is a compile-time constant baked in from whichever
 * headers pkg-config pointed at; this is what the loader really bound. They
 * are normally the same and it matters a great deal when they are not, which
 * is why the two are reported separately. Py_GetVersion is safe before
 * Py_Initialize. */
const char *pg_py_runtime_version(void) { return Py_GetVersion(); }

/* ======================================================================== */
/* Reference counting                                                       */
/* ======================================================================== */

void pg_incref(PyObject *o)  { Py_INCREF(o); }
void pg_decref(PyObject *o)  { Py_DECREF(o); }
void pg_xdecref(PyObject *o) { Py_XDECREF(o); }
pg_ssize_t pg_refcnt(PyObject *o) { return (pg_ssize_t)Py_REFCNT(o); }

/* ======================================================================== */
/* Singletons                                                               */
/* ======================================================================== */

static PyObject *g_empty_bytes = NULL;

PyObject *pg_none(void)  { return Py_None; }
PyObject *pg_true(void)  { return Py_True; }
PyObject *pg_false(void) { return Py_False; }

PyObject *pg_bytes_empty(void) {
    if (!g_empty_bytes) g_empty_bytes = PyBytes_FromStringAndSize("", 0);
    return g_empty_bytes;
}

PyObject *pg_exc_stopiteration(void) { return PyExc_StopIteration; }
PyObject *pg_exc_runtime(void)       { return PyExc_RuntimeError; }
PyObject *pg_exc_value(void)         { return PyExc_ValueError; }
PyObject *pg_exc_type(void)          { return PyExc_TypeError; }
PyObject *pg_exc_os(void)            { return PyExc_OSError; }

/* ======================================================================== */
/* Constructors                                                             */
/* ======================================================================== */

PyObject *pg_bytes(const char *p, pg_ssize_t n) {
    return PyBytes_FromStringAndSize(p, (Py_ssize_t)n);
}

PyObject *pg_bytes_uninit(pg_ssize_t n, char **out) {
    PyObject *b = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)n);
    if (!b) return NULL;
    *out = PyBytes_AS_STRING(b);
    return b;
}

PyObject *pg_str_latin1(const char *p, pg_ssize_t n) {
    /* PEP 3333 native strings are latin-1 decoded bytes. The decoder has a fast
     * path producing a compact 1-byte-kind string with no re-scan. */
    return PyUnicode_DecodeLatin1(p, (Py_ssize_t)n, NULL);
}

PyObject *pg_str_utf8(const char *p, pg_ssize_t n) {
    return PyUnicode_DecodeUTF8(p, (Py_ssize_t)n, "surrogateescape");
}

PyObject *pg_str_intern(const char *s) { return PyUnicode_InternFromString(s); }

PyObject *pg_str_join_comma(PyObject *a, PyObject *b) {
    PyObject *sep = PyUnicode_FromStringAndSize(", ", 2);
    if (!sep) return NULL;
    PyObject *left = PyUnicode_Concat(a, sep);
    Py_DECREF(sep);
    if (!left) return NULL;
    PyObject *out = PyUnicode_Concat(left, b);
    Py_DECREF(left);
    return out;
}

PyObject *pg_int(long v) { return PyLong_FromLong(v); }

PyObject *pg_tuple2(PyObject *a, PyObject *b) {
    PyObject *t = PyTuple_New(2);
    if (!t) return NULL;
    Py_INCREF(a);
    Py_INCREF(b);
    PyTuple_SET_ITEM(t, 0, a);
    PyTuple_SET_ITEM(t, 1, b);
    return t;
}

pg_ssize_t pg_tuple_size(PyObject *t) { return (pg_ssize_t)PyTuple_GET_SIZE(t); }
PyObject *pg_tuple_get(PyObject *t, pg_ssize_t i) {
    return PyTuple_GET_ITEM(t, (Py_ssize_t)i);
}
int pg_is_tuple(PyObject *o) { return PyTuple_Check(o); }

PyObject *pg_list_new(pg_ssize_t n)  { return PyList_New((Py_ssize_t)n); }
void pg_list_set(PyObject *l, pg_ssize_t i, PyObject *v) {
    PyList_SET_ITEM(l, (Py_ssize_t)i, v);
}
PyObject *pg_list_empty_new(void)    { return PyList_New(0); }
int pg_list_append(PyObject *l, PyObject *v) { return PyList_Append(l, v); }
pg_ssize_t pg_list_size(PyObject *l) { return (pg_ssize_t)PyList_GET_SIZE(l); }
PyObject *pg_list_get(PyObject *l, pg_ssize_t i) {
    return PyList_GET_ITEM(l, (Py_ssize_t)i);
}

PyObject *pg_dict_new(void) { return PyDict_New(); }
PyObject *pg_dict_copy(PyObject *d) { return PyDict_Copy(d); }
int pg_dict_contains(PyObject *d, PyObject *k) { return PyDict_Contains(d, k); }
int pg_dict_set(PyObject *d, PyObject *k, PyObject *v) { return PyDict_SetItem(d, k, v); }
PyObject *pg_dict_get(PyObject *d, PyObject *k) {
    PyObject *v = PyDict_GetItemWithError(d, k);
    if (!v) PyErr_Clear();
    return v;
}

/* ======================================================================== */
/* Accessors                                                                */
/* ======================================================================== */

const char *pg_bytes_data(PyObject *o) { return PyBytes_AS_STRING(o); }
pg_ssize_t  pg_bytes_len(PyObject *o)  { return (pg_ssize_t)PyBytes_GET_SIZE(o); }

int pg_as_bytes(PyObject *o, const char **data, pg_ssize_t *len, PyObject **owner) {
    *owner = NULL;
    if (PyBytes_CheckExact(o)) {
        *data = PyBytes_AS_STRING(o);
        *len = (pg_ssize_t)PyBytes_GET_SIZE(o);
        return 0;
    }
    if (PyByteArray_Check(o)) {
        *data = PyByteArray_AS_STRING(o);
        *len = (pg_ssize_t)PyByteArray_GET_SIZE(o);
        return 0;
    }
    if (PyObject_CheckBuffer(o)) {
        /* Materialise into a bytes object we own. Slower, but memoryview and
         * friends are not the common path. */
        PyObject *b = PyBytes_FromObject(o);
        if (!b) return -1;
        *owner = b;
        *data = PyBytes_AS_STRING(b);
        *len = (pg_ssize_t)PyBytes_GET_SIZE(b);
        return 0;
    }
    PyErr_SetString(PyExc_TypeError, "expected a bytes-like object");
    return -1;
}

void pg_release_bytes(PyObject *owner) { Py_XDECREF(owner); }

const char *pg_str_utf8_data(PyObject *o, pg_ssize_t *len) {
    Py_ssize_t n = 0;
    const char *p = PyUnicode_AsUTF8AndSize(o, &n);
    *len = (pg_ssize_t)n;
    return p;
}

const char *pg_str_latin1_data(PyObject *o, pg_ssize_t *len) {
    if (!PyUnicode_Check(o)) return NULL;
    if (PyUnicode_READY(o) < 0) return NULL;
    if (PyUnicode_KIND(o) != PyUnicode_1BYTE_KIND) return NULL;
    *len = (pg_ssize_t)PyUnicode_GET_LENGTH(o);
    return (const char *)PyUnicode_1BYTE_DATA(o);
}

int pg_is_bytes(PyObject *o) { return PyBytes_Check(o); }
int pg_is_str(PyObject *o)   { return PyUnicode_Check(o); }
int pg_is_dict(PyObject *o)  { return PyDict_Check(o); }
int pg_is_list(PyObject *o)  { return PyList_Check(o); }
int pg_is_true(PyObject *o)  { return PyObject_IsTrue(o); }
int pg_is(PyObject *a, PyObject *b) { return a == b; }
int pg_is_callable(PyObject *o) { return PyCallable_Check(o); }
long pg_int_as_long(PyObject *o) { return PyLong_AsLong(o); }

PyObject *pg_getattr(PyObject *o, const char *name) { return PyObject_GetAttrString(o, name); }
PyObject *pg_getattr_obj(PyObject *o, PyObject *name) { return PyObject_GetAttr(o, name); }
int pg_hasattr(PyObject *o, const char *name) { return PyObject_HasAttrString(o, name); }

/* ======================================================================== */
/* Calls                                                                    */
/* ======================================================================== */

PyObject *pg_call0(PyObject *f) {
    return PyObject_Vectorcall(f, NULL, 0, NULL);
}
PyObject *pg_call1(PyObject *f, PyObject *a) {
    PyObject *args[1];
    args[0] = a;
    return PyObject_Vectorcall(f, args, 1, NULL);
}
PyObject *pg_call2(PyObject *f, PyObject *a, PyObject *b) {
    PyObject *args[2];
    args[0] = a; args[1] = b;
    return PyObject_Vectorcall(f, args, 2, NULL);
}
PyObject *pg_call3(PyObject *f, PyObject *a, PyObject *b, PyObject *c) {
    PyObject *args[3];
    args[0] = a; args[1] = b; args[2] = c;
    return PyObject_Vectorcall(f, args, 3, NULL);
}

/* PyObject_VectorcallMethod skips materialising a bound method object. */
PyObject *pg_call_method0(PyObject *self, PyObject *name) {
    PyObject *args[1];
    args[0] = self;
    return PyObject_VectorcallMethod(name, args, 1 | PY_VECTORCALL_ARGUMENTS_OFFSET, NULL);
}
PyObject *pg_call_method1(PyObject *self, PyObject *name, PyObject *a) {
    PyObject *args[2];
    args[0] = self; args[1] = a;
    return PyObject_VectorcallMethod(name, args, 2 | PY_VECTORCALL_ARGUMENTS_OFFSET, NULL);
}
PyObject *pg_call_method2(PyObject *self, PyObject *name, PyObject *a, PyObject *b) {
    PyObject *args[3];
    args[0] = self; args[1] = a; args[2] = b;
    return PyObject_VectorcallMethod(name, args, 3 | PY_VECTORCALL_ARGUMENTS_OFFSET, NULL);
}

PyObject *pg_iter(PyObject *o) { return PyObject_GetIter(o); }
PyObject *pg_iter_next(PyObject *it) { return PyIter_Next(it); }

/* ======================================================================== */
/* Errors                                                                   */
/* ======================================================================== */

int  pg_err_check(void) { return PyErr_Occurred() != NULL; }
void pg_err_clear(void) { PyErr_Clear(); }
void pg_err_print(void) { PyErr_Print(); }

void pg_err_set_stop_iteration(PyObject *value) {
    PyErr_SetObject(PyExc_StopIteration, value ? value : Py_None);
}
void pg_err_set_str(PyObject *exc, const char *msg) { PyErr_SetString(exc, msg); }
void pg_err_restore_from_exc_info(PyObject *triple) {
    if (!PyTuple_Check(triple) || PyTuple_GET_SIZE(triple) != 3) {
        PyErr_SetString(PyExc_TypeError, "exc_info must be a 3-tuple");
        return;
    }
    PyObject *type = PyTuple_GET_ITEM(triple, 0);
    PyObject *value = PyTuple_GET_ITEM(triple, 1);
    PyObject *tb = PyTuple_GET_ITEM(triple, 2);
    Py_XINCREF(type);
    Py_XINCREF(value);
    Py_XINCREF(tb);
    PyErr_Restore(type, value, tb);
}

int  pg_err_matches(PyObject *exc) {
    return PyErr_Occurred() != NULL && PyErr_ExceptionMatches(exc);
}

pg_ssize_t pg_err_format(char *buf, pg_ssize_t cap) {
    if (!PyErr_Occurred() || cap <= 0) return 0;

    PyObject *type = NULL, *value = NULL, *tb = NULL;
    PyErr_Fetch(&type, &value, &tb);
    PyErr_NormalizeException(&type, &value, &tb);
    if (tb && value) PyException_SetTraceback(value, tb);

    Py_ssize_t written = 0;
    PyObject *mod = PyImport_ImportModule("traceback");
    if (mod && value) {
        PyObject *fn = PyObject_GetAttrString(mod, "format_exception");
        if (fn) {
            PyObject *lines = PyObject_CallOneArg(fn, value);
            if (lines) {
                PyObject *sep = PyUnicode_FromStringAndSize("", 0);
                PyObject *joined = sep ? PyUnicode_Join(sep, lines) : NULL;
                if (joined) {
                    Py_ssize_t n = 0;
                    const char *s = PyUnicode_AsUTF8AndSize(joined, &n);
                    if (s) {
                        if (n > (Py_ssize_t)cap) n = (Py_ssize_t)cap;
                        memcpy(buf, s, (size_t)n);
                        written = n;
                    }
                    Py_DECREF(joined);
                }
                Py_XDECREF(sep);
                Py_DECREF(lines);
            }
            Py_DECREF(fn);
        }
    }
    if (written == 0 && value) {
        PyObject *s = PyObject_Str(value);
        if (s) {
            Py_ssize_t n = 0;
            const char *p = PyUnicode_AsUTF8AndSize(s, &n);
            if (p) {
                if (n > (Py_ssize_t)cap) n = (Py_ssize_t)cap;
                memcpy(buf, p, (size_t)n);
                written = n;
            }
            Py_DECREF(s);
        }
    }
    PyErr_Clear();
    Py_XDECREF(mod);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(tb);
    return (pg_ssize_t)written;
}

/* ======================================================================== */
/* Custom types                                                             */
/* ======================================================================== */

typedef struct {
    PyObject_HEAD
    void *ctx;
    void *ctx2;
    int64_t i0;
    int64_t i1;
    PyObject *ref;
    PyObject *ref2;
    PyObject *ref3;
} PgObject;

pg_ssize_t pg_obj_basicsize(void) { return (pg_ssize_t)sizeof(PgObject); }

void pg_slot_set(pg_type_slot *slots, int index, int kind, void *fn) {
    int id = 0;
    switch (kind) {
        case 1: id = Py_tp_dealloc;  break;
        case 2: id = Py_tp_call;     break;
        case 3: id = Py_tp_iter;     break;
        case 4: id = Py_tp_iternext; break;
        case 5: id = Py_tp_methods;  break;
        case 6: id = Py_am_await;    break;
        default: id = 0;             break;
    }
    slots[index].slot = id;
    slots[index].pfunc = fn;
}

void pg_slot_end(pg_type_slot *slots, int index) {
    slots[index].slot = 0;
    slots[index].pfunc = NULL;
}

void pg_method_set(pg_method_def *methods, int index, const char *name,
                   void *fn, int kind) {
    int flags = 0;
    switch (kind) {
        case 1: flags = METH_NOARGS;   break;
        case 2: flags = METH_O;        break;
        case 3: flags = METH_VARARGS;  break;
        case 4: flags = METH_FASTCALL; break;
        default: flags = METH_NOARGS;  break;
    }
    methods[index].ml_name = name;
    methods[index].ml_meth = fn;
    methods[index].ml_flags = flags;
    methods[index].ml_doc = NULL;
}

void pg_method_end(pg_method_def *methods, int index) {
    methods[index].ml_name = NULL;
    methods[index].ml_meth = NULL;
    methods[index].ml_flags = 0;
    methods[index].ml_doc = NULL;
}

PyObject *pg_type_new(const char *name, pg_type_slot *slots, pg_ssize_t basicsize) {
    PyType_Spec spec;
    memset(&spec, 0, sizeof spec);
    spec.name = name;
    spec.basicsize = (int)basicsize;
    spec.itemsize = 0;
    spec.flags = Py_TPFLAGS_DEFAULT
#ifdef Py_TPFLAGS_IMMUTABLETYPE
                 | Py_TPFLAGS_IMMUTABLETYPE
#endif
#ifdef Py_TPFLAGS_DISALLOW_INSTANTIATION
                 | Py_TPFLAGS_DISALLOW_INSTANTIATION
#endif
                 ;
    spec.slots = (PyType_Slot *)slots;
    /* No Py_TPFLAGS_HAVE_GC: these objects are internal, short lived and never
     * form reference cycles, so leaving them untracked removes them from every
     * generational GC pass -- which matters when we mint two or three of them
     * per request. */
    return PyType_FromSpec(&spec);
}

PyObject *pg_obj_alloc(PyObject *type) {
    PyTypeObject *tp = (PyTypeObject *)type;
    PgObject *o = (PgObject *)PyType_GenericAlloc(tp, 0);
    if (!o) return NULL;
    o->ctx = NULL;
    o->ctx2 = NULL;
    o->i0 = 0;
    o->i1 = 0;
    o->ref = NULL;
    o->ref2 = NULL;
    o->ref3 = NULL;
    return (PyObject *)o;
}

void pg_obj_free(PyObject *self) {
    PgObject *o = (PgObject *)self;
    Py_CLEAR(o->ref);
    Py_CLEAR(o->ref2);
    Py_CLEAR(o->ref3);
    PyTypeObject *tp = Py_TYPE(self);
    tp->tp_free(self);
    /* Instances of heap types hold a reference to their type since 3.8. */
    Py_DECREF(tp);
}

void *pg_obj_ctx(PyObject *o)  { return ((PgObject *)o)->ctx; }
void  pg_obj_set_ctx(PyObject *o, void *p) { ((PgObject *)o)->ctx = p; }
void *pg_obj_ctx2(PyObject *o) { return ((PgObject *)o)->ctx2; }
void  pg_obj_set_ctx2(PyObject *o, void *p) { ((PgObject *)o)->ctx2 = p; }
int64_t pg_obj_i0(PyObject *o) { return ((PgObject *)o)->i0; }
void  pg_obj_set_i0(PyObject *o, int64_t v) { ((PgObject *)o)->i0 = v; }
int64_t pg_obj_i1(PyObject *o) { return ((PgObject *)o)->i1; }
void  pg_obj_set_i1(PyObject *o, int64_t v) { ((PgObject *)o)->i1 = v; }
PyObject *pg_obj_ref(PyObject *o) { return ((PgObject *)o)->ref; }
void pg_obj_set_ref(PyObject *o, PyObject *v) {
    PgObject *p = (PgObject *)o;
    PyObject *old = p->ref;
    p->ref = v;
    Py_XDECREF(old);
}
PyObject *pg_obj_ref2(PyObject *o) { return ((PgObject *)o)->ref2; }
void pg_obj_set_ref2(PyObject *o, PyObject *v) {
    PgObject *p = (PgObject *)o;
    PyObject *old = p->ref2;
    p->ref2 = v;
    Py_XDECREF(old);
}
PyObject *pg_obj_ref3(PyObject *o) { return ((PgObject *)o)->ref3; }
void pg_obj_set_ref3(PyObject *o, PyObject *v) {
    PgObject *p = (PgObject *)o;
    PyObject *old = p->ref3;
    p->ref3 = v;
    Py_XDECREF(old);
}

/* ======================================================================== */
/* GIL                                                                      */
/* ======================================================================== */

PyThreadState *pg_gil_save(void) { return PyEval_SaveThread(); }
void pg_gil_restore(PyThreadState *ts) { PyEval_RestoreThread(ts); }
int  pg_gil_ensure(void) { return (int)PyGILState_Ensure(); }
void pg_gil_release(int state) { PyGILState_Release((PyGILState_STATE)state); }
