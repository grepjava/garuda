/*
 * SQLite, loaded at run time.
 *
 * The system's libsqlite3 is opened with dlopen the first time it is asked
 * for, so building Garuda needs no SQLite headers and a program that never
 * opens a database never loads the library. Each gsq_ function calls the
 * library's function of the same name; where the library cannot be loaded,
 * gsq_available says so and nothing else may be called.
 *
 * The handles are the library's own, left opaque.
 */
#ifndef GARUDA_SQLITE_H
#define GARUDA_SQLITE_H

#include <stdint.h>

typedef struct gsq_db gsq_db;
typedef struct gsq_stmt gsq_stmt;

/* Result codes. The rest are passed through as numbers. */
#define GSQ_OK 0
#define GSQ_ERROR 1
#define GSQ_BUSY 5
#define GSQ_LOCKED 6
#define GSQ_NOMEM 7
#define GSQ_READONLY 8
#define GSQ_INTERRUPT 9
#define GSQ_CONSTRAINT 19
#define GSQ_MISUSE 21
#define GSQ_RANGE 25
#define GSQ_ROW 100
#define GSQ_DONE 101

/* Open flags. */
#define GSQ_OPEN_READONLY 0x00000001
#define GSQ_OPEN_READWRITE 0x00000002
#define GSQ_OPEN_CREATE 0x00000004
#define GSQ_OPEN_NOMUTEX 0x00008000
#define GSQ_OPEN_PRIVATECACHE 0x00040000

/* Column types. */
#define GSQ_INTEGER 1
#define GSQ_FLOAT 2
#define GSQ_TEXT 3
#define GSQ_BLOB 4
#define GSQ_NULL 5

/* 1 when the library is loaded, has every function used here, and was built
 * to be used from more than one thread. */
int gsq_available(void);
/* The library's version as a number: 3045001 for 3.45.1. 0 if not loaded. */
int gsq_libversion_number(void);

/* A handle may come back with an error, and must then still be closed. */
int gsq_open(const char *path, int flags, gsq_db **db);
int gsq_close(gsq_db *db);
const char *gsq_errmsg(gsq_db *db);
int gsq_extended_errcode(gsq_db *db);
const char *gsq_errstr(int code);
int gsq_extended_result_codes(gsq_db *db, int on);
int gsq_busy_timeout(gsq_db *db, int milliseconds);
int gsq_get_autocommit(gsq_db *db);
int64_t gsq_changes(gsq_db *db);
int64_t gsq_last_insert_rowid(gsq_db *db);
void gsq_interrupt(gsq_db *db);
/* Sleeps the calling thread for at least `milliseconds`. */
void gsq_sleep(int milliseconds);

/* `tail` is where the first statement ended, within `sql`. */
int gsq_prepare(gsq_db *db, const char *sql, int bytes, gsq_stmt **stmt, const char **tail);
int gsq_step(gsq_stmt *stmt);
int gsq_reset(gsq_stmt *stmt);
int gsq_clear_bindings(gsq_stmt *stmt);
int gsq_finalize(gsq_stmt *stmt);
int gsq_stmt_readonly(gsq_stmt *stmt);
int gsq_bind_parameter_count(gsq_stmt *stmt);

/* Text and blobs are copied. An empty one binds as empty, not as NULL. */
int gsq_bind_null(gsq_stmt *stmt, int index);
int gsq_bind_int64(gsq_stmt *stmt, int index, int64_t value);
int gsq_bind_double(gsq_stmt *stmt, int index, double value);
int gsq_bind_text(gsq_stmt *stmt, int index, const char *text, int bytes);
int gsq_bind_blob(gsq_stmt *stmt, int index, const void *data, int bytes);

int gsq_column_count(gsq_stmt *stmt);
const char *gsq_column_name(gsq_stmt *stmt, int column);
int gsq_column_type(gsq_stmt *stmt, int column);
int64_t gsq_column_int64(gsq_stmt *stmt, int column);
double gsq_column_double(gsq_stmt *stmt, int column);
/* Call before gsq_column_bytes, as the library asks. */
const unsigned char *gsq_column_text(gsq_stmt *stmt, int column);
const void *gsq_column_blob(gsq_stmt *stmt, int column);
int gsq_column_bytes(gsq_stmt *stmt, int column);

#endif
