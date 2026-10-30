#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <unistd.h>
#endif

typedef struct {
  JSRuntime *runtime;
  JSContext *context;
  int64_t deadline_ns;
} EmbeddedJs;

static int64_t monotonic_ns(void) {
  struct timespec time;
  clock_gettime(CLOCK_MONOTONIC, &time);
  return (int64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}

static int interrupted(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  EmbeddedJs *js = opaque;
  return monotonic_ns() >= js->deadline_ns;
}

static char *copy_result(char kind, const char *value) {
  if (!value) value = "QuickJS allocation failed";
  size_t size = strlen(value);
  char *result = malloc(size + 2);
  if (!result) return NULL;
  result[0] = kind;
  memcpy(result + 1, value, size + 1);
  return result;
}

static char *exception(EmbeddedJs *js) {
  JSValue error = JS_GetException(js->context);
  const char *message = JS_ToCString(js->context, error);
  char *result = copy_result('E', message);
  if (message) JS_FreeCString(js->context, message);
  JS_FreeValue(js->context, error);
  return result;
}

EmbeddedJs *embedded_js_new(int64_t memory_limit) {
  EmbeddedJs *js = calloc(1, sizeof(EmbeddedJs));
  if (!js) return NULL;
  js->runtime = JS_NewRuntime();
  if (!js->runtime) { free(js); return NULL; }
  JS_SetMemoryLimit(js->runtime, (size_t)memory_limit);
  JS_SetMaxStackSize(js->runtime, 512 * 1024);
  JS_SetGCThreshold(js->runtime, 4 * 1024 * 1024);
  JS_SetInterruptHandler(js->runtime, interrupted, js);
  js->context = JS_NewContext(js->runtime);
  if (!js->context) { JS_FreeRuntime(js->runtime); free(js); return NULL; }
  return js;
}

void embedded_js_reset_context(EmbeddedJs *js) {
  JS_UpdateStackTop(js->runtime);
  JS_FreeContext(js->context);
  JS_RunGC(js->runtime);
  js->context = JS_NewContext(js->runtime);
}

char *embedded_js_eval(EmbeddedJs *js, const char *source, int64_t budget_ms) {
  if (!js->context) return copy_result('E', "QuickJS context allocation failed");
  JS_UpdateStackTop(js->runtime);
  js->deadline_ns = monotonic_ns() + budget_ms * 1000000;
  JSValue value = JS_Eval(js->context, source, strlen(source), "<cell>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) return exception(js);
  JSValue json = JS_JSONStringify(js->context, value, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(js->context, value);
  if (JS_IsException(json)) return exception(js);
  if (JS_IsUndefined(json)) return copy_result('J', "null");
  const char *text = JS_ToCString(js->context, json);
  char *result = copy_result('J', text ? text : "null");
  if (text) JS_FreeCString(js->context, text);
  JS_FreeValue(js->context, json);
  return result;
}

char *embedded_js_pump(EmbeddedJs *js, int32_t limit, int64_t budget_ms) {
  JS_UpdateStackTop(js->runtime);
  js->deadline_ns = monotonic_ns() + budget_ms * 1000000;
  for (int32_t i = 0; i < limit && JS_IsJobPending(js->runtime); i++) {
    JSContext *context = NULL;
    if (JS_ExecutePendingJob(js->runtime, &context) < 0) return exception(js);
    if (monotonic_ns() >= js->deadline_ns) break;
  }
  return NULL;
}

void embedded_js_free(EmbeddedJs *js) {
  if (!js) return;
  JS_UpdateStackTop(js->runtime);
  if (js->context) JS_FreeContext(js->context);
  JS_FreeRuntime(js->runtime);
  free(js);
}

void embedded_js_string_free(char *text) { free(text); }

int32_t embedded_js_has_jobs(EmbeddedJs *js) { return JS_IsJobPending(js->runtime); }

uint64_t embedded_js_thread_id(void) {
#ifdef __APPLE__
  uint64_t id = 0;
  pthread_threadid_np(NULL, &id);
  return id;
#elif defined(__linux__)
  return (uint64_t)syscall(SYS_gettid);
#else
  return (uint64_t)(uintptr_t)pthread_self();
#endif
}
