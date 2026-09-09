#ifndef PEREGRINE_PY_H
#define PEREGRINE_PY_H

/* ---------------------------------------------------------------------------
 * CPython bridge.
 *
 * Everything in the CPython API that Swift cannot see -- macros, static inline
 * functions, variadic functions, and the enormous PyConfig struct -- is wrapped
 * here as a plain extern "C" function. The Swift side then deals only with
 * opaque PyObject pointers, which lets us keep Python reference counting
 * entirely outside of Swift ARC: a Python object is owned by a ~Copyable PyRef
 * whose deinit calls pg_decref, and no Swift retain/release ever runs for it.
 *
 * IMPORTANT: this header must never include <Python.h>.
 *
 * Python.h defines _XOPEN_SOURCE / _POSIX_C_SOURCE, which flips __USE_XOPEN in
 * glibc and changes the member names of `fd_set` (fds_bits vs __fds_bits). Any
 * Swift file that imported both this module and Glibc would then see two
 * incompatible definitions of the same C type and fail to compile. Keeping
 * Python.h confined to the .c file removes the whole class of problem, at the
 * cost of mirroring a few tiny CPython structs below -- each of which is
 * static_assert-ed against the real thing in peregrine_py.c.
 * ------------------------------------------------------------------------- */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _object PyObject;
typedef struct _ts PyThreadState;
typedef ptrdiff_t pg_ssize_t;              /* mirrors Py_ssize_t */

/* mirrors PyType_Slot */
typedef struct { int slot; void *pfunc; } pg_type_slot;
/* mirrors PyMethodDef */
typedef struct {
    const char *ml_name;
    void *ml_meth;
    int ml_flags;
    const char *ml_doc;
} pg_method_def;

/* Which slot a pg_type_slot entry fills, and how a method is called. These are
 * passed as plain ints so that Swift sees an unambiguous parameter type rather
 * than a C enum whose import shape varies. The implementation maps them onto
 * the real Py_* slot ids and METH_* flags.
 *
 *   slot kinds:  1 dealloc, 2 call, 3 iter, 4 iternext, 5 methods, 6 await
 *   meth kinds:  1 noargs,  2 O,    3 varargs, 4 fastcall
 */

/* --- interpreter lifecycle ---------------------------------------------- */

int   pg_py_init(const char *program, const char *pyhome, int isolated);
void  pg_py_finalize(void);
int   pg_py_add_syspath(const char *dir);
PyObject *pg_py_import(const char *name);
/* Creates a module, execs `src` in its dict, returns a new reference. Used for
 * the handful of asyncio glue lines that are far cheaper to express in Python
 * than through twenty C-API calls. */
PyObject *pg_py_exec_module(const char *name, const char *src);
int   pg_py_version_hex(void);
/* Version string of the libpython that was actually linked. Safe to call
 * before pg_py_init. */
const char *pg_py_runtime_version(void);
int   pg_py_is_initialized(void);

/* --- reference counting -------------------------------------------------- */

void  pg_incref(PyObject *o);
void  pg_decref(PyObject *o);
void  pg_xdecref(PyObject *o);
pg_ssize_t pg_refcnt(PyObject *o);

/* --- singletons and exception types -------------------------------------- */

PyObject *pg_none(void);
PyObject *pg_true(void);
PyObject *pg_false(void);
PyObject *pg_bytes_empty(void);
PyObject *pg_exc_stopiteration(void);
PyObject *pg_exc_runtime(void);
PyObject *pg_exc_value(void);
PyObject *pg_exc_type(void);
PyObject *pg_exc_os(void);

/* --- constructors -------------------------------------------------------- */

PyObject *pg_bytes(const char *p, pg_ssize_t n);
/* Uninitialised bytes object plus a writable pointer: lets us build a request
 * chunk with exactly one allocation and one memcpy. */
PyObject *pg_bytes_uninit(pg_ssize_t n, char **out);
PyObject *pg_str_latin1(const char *p, pg_ssize_t n);   /* WSGI native strings */
PyObject *pg_str_utf8(const char *p, pg_ssize_t n);
PyObject *pg_str_intern(const char *s);
/* a + ", " + b, for the PEP 3333 rule that repeated request headers are
 * folded into one comma-separated environ value. */
PyObject *pg_str_join_comma(PyObject *a, PyObject *b);
PyObject *pg_int(long v);
PyObject *pg_tuple2(PyObject *a, PyObject *b);          /* new refs to a, b */
pg_ssize_t pg_tuple_size(PyObject *t);
PyObject *pg_tuple_get(PyObject *t, pg_ssize_t i);      /* borrowed */
int       pg_is_tuple(PyObject *o);
PyObject *pg_list_new(pg_ssize_t n);                    /* preallocated, all NULL */
void      pg_list_set(PyObject *l, pg_ssize_t i, PyObject *v);  /* steals v */
PyObject *pg_list_empty_new(void);
int       pg_list_append(PyObject *l, PyObject *v);     /* borrows v */
pg_ssize_t pg_list_size(PyObject *l);
PyObject *pg_list_get(PyObject *l, pg_ssize_t i);       /* borrowed */
PyObject *pg_dict_new(void);
/* Shallow copy. Copying a prepared prototype beats re-inserting the fifteen
 * constant WSGI environ entries on every request. */
PyObject *pg_dict_copy(PyObject *d);
/* Read-only view. Interned scope dicts are shared across requests; a proxy
 * is what makes "applications are not entitled to mutate this" true. */
PyObject *pg_mapping_proxy(PyObject *d);
int       pg_dict_contains(PyObject *d, PyObject *k);
int       pg_dict_set(PyObject *d, PyObject *k, PyObject *v);
PyObject *pg_dict_get(PyObject *d, PyObject *k);        /* borrowed, NULL if absent */

/* --- accessors ----------------------------------------------------------- */

const char *pg_bytes_data(PyObject *o);
pg_ssize_t  pg_bytes_len(PyObject *o);
/* bytes / bytearray / any buffer-protocol object. `owner` receives a temporary
 * that must be released with pg_release_bytes once the data is consumed. */
int  pg_as_bytes(PyObject *o, const char **data, pg_ssize_t *len, PyObject **owner);
void pg_release_bytes(PyObject *owner);
const char *pg_str_utf8_data(PyObject *o, pg_ssize_t *len);
/* Zero-copy latin-1 view of a compact 1-byte string, which is what every WSGI
 * native string produced from request bytes actually is. Returns NULL for wider
 * strings so the caller can fall back to encoding. */
const char *pg_str_latin1_data(PyObject *o, pg_ssize_t *len);
int  pg_is_bytes(PyObject *o);
int  pg_is_str(PyObject *o);
int  pg_is_dict(PyObject *o);
int  pg_is_list(PyObject *o);
int  pg_is_true(PyObject *o);          /* PyObject_IsTrue, -1 on error */
int  pg_is(PyObject *a, PyObject *b);  /* identity */
int  pg_is_callable(PyObject *o);
long pg_int_as_long(PyObject *o);      /* -1 + error on failure */
PyObject *pg_getattr(PyObject *o, const char *name);
PyObject *pg_getattr_obj(PyObject *o, PyObject *name);
int pg_hasattr(PyObject *o, const char *name);

/* --- calls (vectorcall: no intermediate tuple allocated) ----------------- */

PyObject *pg_call0(PyObject *f);
PyObject *pg_call1(PyObject *f, PyObject *a);
PyObject *pg_call2(PyObject *f, PyObject *a, PyObject *b);
PyObject *pg_call3(PyObject *f, PyObject *a, PyObject *b, PyObject *c);
PyObject *pg_call_method0(PyObject *self, PyObject *name);
PyObject *pg_call_method1(PyObject *self, PyObject *name, PyObject *a);
PyObject *pg_call_method2(PyObject *self, PyObject *name, PyObject *a, PyObject *b);

/* --- iteration ----------------------------------------------------------- */

PyObject *pg_iter(PyObject *o);
PyObject *pg_iter_next(PyObject *it);   /* NULL + no error == exhausted */

/* --- errors -------------------------------------------------------------- */

int  pg_err_check(void);
void pg_err_clear(void);
void pg_err_print(void);
/* Formats the pending exception (with traceback) into `buf`, clears it, and
 * returns the number of bytes written. Never allocates on the Swift side. */
pg_ssize_t pg_err_format(char *buf, pg_ssize_t cap);
void pg_err_set_stop_iteration(PyObject *value);   /* NULL means None */
void pg_err_set_str(PyObject *exc, const char *msg);
int  pg_err_matches(PyObject *exc);
/* Re-raise from a PEP 3333 exc_info triple. */
void pg_err_restore_from_exc_info(PyObject *triple);

/* --- custom types -------------------------------------------------------- */

/* Instance layout shared by every Swift-defined Python type: two raw context
 * words, two integers and one owned object reference. One layout for all of
 * them (send/receive callables, awaitables, the WSGI input stream) keeps the
 * allocator warm and the code small. */
pg_ssize_t pg_obj_basicsize(void);
void       pg_slot_set(pg_type_slot *slots, int index, int kind, void *fn);
void       pg_slot_end(pg_type_slot *slots, int index);
void       pg_method_set(pg_method_def *methods, int index, const char *name,
                         void *fn, int kind);
void       pg_method_end(pg_method_def *methods, int index);
PyObject  *pg_type_new(const char *name, pg_type_slot *slots, pg_ssize_t basicsize);
PyObject  *pg_obj_alloc(PyObject *type);
void       pg_obj_free(PyObject *self);      /* tp_free + heap-type decref */
void      *pg_obj_ctx(PyObject *o);
void       pg_obj_set_ctx(PyObject *o, void *p);
void      *pg_obj_ctx2(PyObject *o);
void       pg_obj_set_ctx2(PyObject *o, void *p);
int64_t    pg_obj_i0(PyObject *o);
void       pg_obj_set_i0(PyObject *o, int64_t v);
int64_t    pg_obj_i1(PyObject *o);
void       pg_obj_set_i1(PyObject *o, int64_t v);
/* Three owned-object slots. Three is what the busiest instance needs (WSGI
 * start_response holds status, headers and the legacy write() buffer), and one
 * uniform layout for every internal type keeps allocation on the free list. */
PyObject  *pg_obj_ref(PyObject *o);                   /* borrowed */
void       pg_obj_set_ref(PyObject *o, PyObject *v);  /* steals v, drops old */
PyObject  *pg_obj_ref2(PyObject *o);
void       pg_obj_set_ref2(PyObject *o, PyObject *v);
PyObject  *pg_obj_ref3(PyObject *o);
void       pg_obj_set_ref3(PyObject *o, PyObject *v);

/* --- GIL ----------------------------------------------------------------- */

PyThreadState *pg_gil_save(void);
void pg_gil_restore(PyThreadState *ts);
int  pg_gil_ensure(void);        /* PyGILState_Ensure, returned as int */
void pg_gil_release(int state);

#ifdef __cplusplus
}
#endif
#endif
