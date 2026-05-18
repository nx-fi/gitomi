#include "sqlite3.h"

int sqlite_bind_text_transient(sqlite3_stmt *stmt, int index, const char *value, int len) {
    return sqlite3_bind_text(stmt, index, value, len, SQLITE_TRANSIENT);
}
