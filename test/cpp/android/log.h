#ifndef TEST_ANDROID_LOG_STUB_H
#define TEST_ANDROID_LOG_STUB_H

// Host stub for <android/log.h> — allows production audio_mixer.cpp to compile
// in CI without the Android NDK. Maps Android log calls to printf so test
// output stays readable.

#include <cstdio>

#define ANDROID_LOG_INFO 0
#define ANDROID_LOG_WARN 1
#define ANDROID_LOG_ERROR 2

#define __android_log_print(priority, tag, ...) \
    do { \
        printf("[%s] ", tag); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } while (0)

#endif // TEST_ANDROID_LOG_STUB_H
