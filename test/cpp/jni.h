#ifndef TEST_JNI_STUB_H
#define TEST_JNI_STUB_H

// Host stub for <jni.h> — allows production code to compile in CI without the
// Android NDK. Extended from the original mixer-only stub to cover the full JNI
// surface used by peer_audio_manager.cpp (JavaVM attach/detach, callback
// dispatch, array/string marshaling).
//
// None of the methods here are called in unit tests; they exist only so the
// translation unit compiles cleanly.

#define JNIEXPORT
#define JNICALL

// Primitive types
typedef int jint;
typedef long long jlong;
typedef short jshort;
typedef signed char jbyte;
typedef int jsize;
typedef unsigned char jboolean;

// Opaque reference handles
typedef void* jobject;
typedef void* jclass;
typedef void* jmethodID;
typedef void* jstring;
typedef void* jarray;
typedef void* jbyteArray;
typedef void* jshortArray;
typedef void* jintArray;

// Boolean constants
#define JNI_TRUE  ((jboolean)1)
#define JNI_FALSE ((jboolean)0)
#define JNI_ABORT 2

// Version / error constants
#define JNI_VERSION_1_6  0x00010006
#define JNI_OK           0
#define JNI_ERR          (-1)
#define JNI_EDETACHED    (-2)

// Forward declaration for use in JNIEnv::GetJavaVM.
struct JavaVM_;
typedef JavaVM_ JavaVM;

// JNIEnv as a struct so that env->Method() resolves correctly. All methods
// return safe null/zero values; they are dead code in every host test.
struct JNIEnv {
    int GetJavaVM(JavaVM** vm) { if (vm) *vm = nullptr; return JNI_ERR; }

    jobject NewGlobalRef(jobject) { return nullptr; }
    void    DeleteGlobalRef(jobject) {}
    jobject NewLocalRef(jobject) { return nullptr; }
    void    DeleteLocalRef(jobject) {}

    jclass    GetObjectClass(jobject) { return nullptr; }
    jmethodID GetMethodID(jclass, const char*, const char*) { return nullptr; }

    jstring    NewStringUTF(const char*) { return nullptr; }
    const char* GetStringUTFChars(jstring, jboolean*) { return ""; }
    void        ReleaseStringUTFChars(jstring, const char*) {}

    jbyteArray NewByteArray(jsize) { return nullptr; }
    void       SetByteArrayRegion(jbyteArray, jsize, jsize, const jbyte*) {}
    jbyte*     GetByteArrayElements(jbyteArray, jboolean*) { return nullptr; }
    void       ReleaseByteArrayElements(jbyteArray, jbyte*, jint) {}

    jshortArray NewShortArray(jsize) { return nullptr; }
    jshort*     GetShortArrayElements(jshortArray, jboolean*) { return nullptr; }
    void        ReleaseShortArrayElements(jshortArray, jshort*, jint) {}
    void        SetShortArrayRegion(jshortArray, jsize, jsize, const jshort*) {}

    jintArray NewIntArray(jsize) { return nullptr; }
    void      SetIntArrayRegion(jintArray, jsize, jsize, const jint*) {}

    jsize GetArrayLength(jarray) { return 0; }

    // Variadic overload so CallVoidMethod(obj, mid, arg1, arg2, ...) compiles.
    template<typename... Args>
    void CallVoidMethod(jobject, jmethodID, Args...) {}

    jboolean ExceptionCheck() { return JNI_FALSE; }
    void     ExceptionDescribe() {}
    void     ExceptionClear() {}
};

// JavaVM as a struct so that jvm->Method() resolves correctly.
struct JavaVM_ {
    int GetEnv(void** env, int) { if (env) *env = nullptr; return JNI_EDETACHED; }
    int AttachCurrentThread(JNIEnv**, void*) { return JNI_ERR; }
    int DetachCurrentThread() { return JNI_OK; }
};

#endif  // TEST_JNI_STUB_H
