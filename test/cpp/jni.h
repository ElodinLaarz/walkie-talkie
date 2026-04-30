#ifndef TEST_JNI_STUB_H
#define TEST_JNI_STUB_H

// Host stub for <jni.h> — allows production audio_mixer.cpp to compile in CI
// without the Android NDK. Provides minimal type definitions for the JNI entry
// points at the bottom of audio_mixer.cpp (which the test doesn't call).

#define JNIEXPORT
#define JNICALL

typedef void* JNIEnv;
typedef void* jobject;
typedef void* jshortArray;
typedef int jint;
typedef short jshort;
typedef int jsize;
typedef unsigned char jboolean;

#define JNI_TRUE 1
#define JNI_FALSE 0
#define JNI_ABORT 2

#endif // TEST_JNI_STUB_H
