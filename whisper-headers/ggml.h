#ifndef GGML_H
#define GGML_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*ggml_abort_callback)(void * data);
typedef void (*ggml_log_callback)(int level, const char * text, void * user_data);
#ifdef __cplusplus
}
#endif
#endif
