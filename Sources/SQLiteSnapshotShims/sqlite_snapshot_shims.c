#include <sqlite3.h>

// Provide stub implementations for snapshot APIs when SQLite is built without
// SQLITE_ENABLE_SNAPSHOT. This satisfies link requirements on platforms where
// the functions are unavailable (e.g., some Linux distributions).
#if !defined(SQLITE_ENABLE_SNAPSHOT)
int sqlite3_snapshot_open(sqlite3 *db, const char *zSchema, sqlite3_snapshot *pSnapshot) {
    (void)db;
    (void)zSchema;
    (void)pSnapshot;
    return SQLITE_ERROR;
}

int sqlite3_snapshot_get(sqlite3 *db, const char *zSchema, sqlite3_snapshot **ppSnapshot) {
    (void)db;
    (void)zSchema;
    (void)ppSnapshot;
    return SQLITE_ERROR;
}

void sqlite3_snapshot_free(sqlite3_snapshot *pSnapshot) {
    (void)pSnapshot;
}

int sqlite3_snapshot_cmp(sqlite3_snapshot *p1, sqlite3_snapshot *p2) {
    (void)p1;
    (void)p2;
    return SQLITE_ERROR;
}
#endif
