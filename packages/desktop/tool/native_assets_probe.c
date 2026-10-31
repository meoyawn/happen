#include <assert.h>
#include <copyfile.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LOAD(library, symbol) ((__typeof__(&symbol))dlsym(library, #symbol))

// Load using the built manifest, replace the file as a rebuild does, then
// resolve an unused binding against a statement from before the replacement.
int main(int argc, char **argv) {
  assert(argc == 3);
  void *first = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!first) {
    fprintf(stderr, "Initial native asset load failed: %s\n", dlerror());
    return 1;
  }
  sqlite3 *db = NULL;
  sqlite3_stmt *statement = NULL;
  assert(LOAD(first, sqlite3_open)(":memory:", &db) == SQLITE_OK);
  assert(LOAD(first, sqlite3_prepare_v2)(db, "SELECT ?1, ?2", -1, &statement, NULL) == SQLITE_OK);

  struct stat before, after;
  assert(stat(argv[2], &before) == 0);
  char *replacement = NULL;
  assert(asprintf(&replacement, "%s.replacement", argv[2]) > 0);
  assert(copyfile(argv[2], replacement, NULL, COPYFILE_ALL) == 0);
  assert(rename(replacement, argv[2]) == 0);
  free(replacement);
  assert(stat(argv[2], &after) == 0 && before.st_ino != after.st_ino);

  void *later = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  unsigned int mappings = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    if (strstr(_dyld_get_image_name(i), "sqlite3.framework/")) mappings++;
  }
  if (first != later || mappings != 1) {
    fprintf(stderr, "Native asset loaded %u times after replacement; SQLite handles cannot cross library copies.\n", mappings);
    return 1;
  }
  assert(LOAD(later, sqlite3_bind_int64)(statement, 1, 42) == SQLITE_OK);
  assert(LOAD(later, sqlite3_bind_text)(statement, 2, "after-rebuild", -1, SQLITE_STATIC) == SQLITE_OK);
  assert(LOAD(later, sqlite3_step)(statement) == SQLITE_ROW);
  assert(LOAD(later, sqlite3_column_int64)(statement, 0) == 42);
  assert(strcmp((const char *)LOAD(later, sqlite3_column_text)(statement, 1), "after-rebuild") == 0);
  assert(LOAD(later, sqlite3_finalize)(statement) == SQLITE_OK);
  assert(LOAD(later, sqlite3_close)(db) == SQLITE_OK);
  puts("Native asset survived file replacement: one mapping; integer and text bindings succeeded.");
  return 0;
}
