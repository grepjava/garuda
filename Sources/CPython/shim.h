#ifndef PEREGRINE_CPYTHON_SHIM_H
#define PEREGRINE_CPYTHON_SHIM_H

/* Keep the limited-API opt-outs off: we want PyType_FromSpec, vectorcall and
 * the fast unicode accessors, all of which are public but not limited-API. */
#define PY_SSIZE_T_CLEAN 1
#include <Python.h>

#endif
