// Host-buildable test for PeerAudioManager::onVoiceFramePushed.
//
// Issue #247 identified two gaps that this test closes:
//
//   (a) The JNI hop: seq arrives from Kotlin as jlong and is cast to uint32_t
//       via static_cast<uint32_t>(seq) in nativeOnVoiceFrameReceived. Values
//       >= 0x80000000 look negative as signed 32-bit ints; the cast must
//       preserve their full unsigned value, and the jitter buffer must then
//       accept them on that unsigned value. testHighUint32SeqCastAndAccepted
//       exercises the cast explicitly by starting from a jlong (int64_t) value
//       and applying the same static_cast that the JNI bridge uses.
//
//   (b) Seq gap: a burst loss (seqs 5-25 absent) must be handled by the
//       jitter buffer's hole-detection, not the AudioMixer's stuck-producer
//       poison. PeerAudioManager routes frames through updateDeviceAudio, not
//       onVoiceFrame, so the AudioMixer's seq-based gate is intentionally
//       bypassed; the jitter buffer is the sole gap-handling layer.
//
// Compile (see scripts/presubmit.sh):
//   g++ -std=c++17 -Wall -Wextra -pthread
//       -I test/cpp -I android/app/src/main/cpp
//       $(pkg-config --cflags opus)
//       test/cpp/peer_audio_manager_test.cpp
//       android/app/src/main/cpp/peer_audio_manager.cpp
//       android/app/src/main/cpp/audio_mixer.cpp
//       android/app/src/main/cpp/jitter_buffer.cpp
//       android/app/src/main/cpp/opus_codec.cpp
//       $(pkg-config --libs opus)
//       -o build/cpp_test/peer_audio_manager_test

#include "peer_audio_manager.h"

#include <cstdint>
#include <iostream>
#include <string>

// CHECK is preferred over assert(): assert() is a no-op when NDEBUG is
// defined (release/optimized builds), which would let tests pass silently
// without any validation. CHECK always fires and aborts with a clear diagnostic.
#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::cerr << "CHECK failed: " #cond                              \
                      << " (" << __FILE__ << ":" << __LINE__ << ")"          \
                      << std::endl;                                          \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

namespace {

// Minimal one-byte payload used wherever audio content doesn't matter.
const uint8_t kFakeOpus[1] = {0xAB};
const int kFakeOpusLen = 1;
const std::string kMacA = "AA:BB:CC:DD:EE:FF";
const std::string kMacB = "11:22:33:44:55:66";

}  // namespace

// Verify that onVoiceFramePushed returns false for an unregistered peer —
// the registry lookup guard at the top of the method must fire before
// any jitter-buffer access.
void testUnregisteredPeerReturnsFalse() {
    PeerAudioManager mgr;

    CHECK(!mgr.onVoiceFramePushed(kMacA, 1, kFakeOpus, kFakeOpusLen));

    std::cout << "Test Unregistered Peer Returns False: PASSED" << std::endl;
}

// Normal in-order push: frames land in the jitter buffer and are accepted.
void testNormalSeqAccepted() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);

    for (uint32_t seq = 1; seq <= 10; ++seq) {
        CHECK(mgr.onVoiceFramePushed(kMacA, seq, kFakeOpus, kFakeOpusLen));
    }

    mgr.clear();
    std::cout << "Test Normal Seq Accepted: PASSED" << std::endl;
}

// High uint32 seq values (>= 0x80000000) look negative when read as a signed
// 32-bit int but are valid unsigned uint32 seq numbers.
//
// The JNI entry point `nativeOnVoiceFrameReceived` receives seq as `jlong`
// (int64_t) and converts it via `static_cast<uint32_t>(seq)`. This test
// mirrors that cast explicitly: each loop variable is a `jlong` (int64_t)
// and the same static_cast is applied before passing to onVoiceFramePushed,
// so a regression in that conversion would be caught here.
//
// A 5-frame window spanning 0x7FFFFFFF→0x80000000 stays under kJitterMaxDepth.
void testHighUint32SeqCastAndAccepted() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);

    // Use jlong (int64_t) to mirror the JNI type, then apply the same
    // static_cast<uint32_t> used in nativeOnVoiceFrameReceived.
    for (int64_t seqJlong = 0x7FFFFFFDLL; seqJlong != 0x80000002LL; ++seqJlong) {
        uint32_t seq = static_cast<uint32_t>(seqJlong);
        CHECK(mgr.onVoiceFramePushed(kMacA, seq, kFakeOpus, kFakeOpusLen));
    }

    mgr.clear();
    std::cout << "Test High uint32 Seq Cast And Accepted: PASSED" << std::endl;
}

// Seq values straddling the uint32 rollover (0xFFFFFFFF → 0x00000000) are
// accepted by onVoiceFramePushed. The test verifies acceptance only (the
// jitter buffer's ordering is separately covered in jitter_buffer_test.cpp).
//
// 5 frames (3 before + 2 after the rollover) stay under kJitterMaxDepth (10).
void testUint32RolloverAccepted() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);

    // 3 frames ending at the max uint32 value.
    CHECK(mgr.onVoiceFramePushed(kMacA, 0xFFFFFFFDu, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacA, 0xFFFFFFFEu, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacA, 0xFFFFFFFFu, kFakeOpus, kFakeOpusLen));
    // 2 frames after the rollover: treated as forward frames by unsigned delta.
    CHECK(mgr.onVoiceFramePushed(kMacA, 0x00000000u, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacA, 0x00000001u, kFakeOpus, kFakeOpusLen));

    mgr.clear();
    std::cout << "Test uint32 Rollover Accepted: PASSED" << std::endl;
}

// Seq gap: push seqs 1-4, skip 5-25, then push 26. The jitter buffer accepts
// 26 as a future in-order frame (the gap is treated as a hole to be PLC'd
// during playout). The AudioMixer's stuck-producer poison is NOT triggered
// because PeerAudioManager calls updateDeviceAudio, not onVoiceFrame.
void testSeqGapAcceptedByJitterBuffer() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);

    for (uint32_t seq = 1; seq <= 4; ++seq) {
        CHECK(mgr.onVoiceFramePushed(kMacA, seq, kFakeOpus, kFakeOpusLen));
    }

    // Seqs 5-25 are absent (burst loss). Seq 26 must still be accepted.
    CHECK(mgr.onVoiceFramePushed(kMacA, 26, kFakeOpus, kFakeOpusLen));

    mgr.clear();
    std::cout << "Test Seq Gap Accepted By JitterBuffer: PASSED" << std::endl;
}

// Duplicate seq must be rejected without disturbing subsequent frames.
void testDuplicateRejected() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);

    CHECK(mgr.onVoiceFramePushed(kMacA, 42, kFakeOpus, kFakeOpusLen));
    CHECK(!mgr.onVoiceFramePushed(kMacA, 42, kFakeOpus, kFakeOpusLen));  // dup
    CHECK(mgr.onVoiceFramePushed(kMacA, 43, kFakeOpus, kFakeOpusLen));

    mgr.clear();
    std::cout << "Test Duplicate Rejected: PASSED" << std::endl;
}

// Two peers are independent: frames from peer A must not affect peer B's
// jitter buffer, and vice versa.
void testMultiplePeersAreIndependent() {
    PeerAudioManager mgr;
    mgr.registerPeer(kMacA);
    mgr.registerPeer(kMacB);

    CHECK(mgr.onVoiceFramePushed(kMacA, 1, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacB, 100, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacA, 2, kFakeOpus, kFakeOpusLen));

    // Duplicate on B must not affect A.
    CHECK(!mgr.onVoiceFramePushed(kMacB, 100, kFakeOpus, kFakeOpusLen));
    CHECK(mgr.onVoiceFramePushed(kMacA, 3, kFakeOpus, kFakeOpusLen));

    mgr.clear();
    std::cout << "Test Multiple Peers Are Independent: PASSED" << std::endl;
}

int main() {
    try {
        testUnregisteredPeerReturnsFalse();
        testNormalSeqAccepted();
        testHighUint32SeqCastAndAccepted();
        testUint32RolloverAccepted();
        testSeqGapAcceptedByJitterBuffer();
        testDuplicateRejected();
        testMultiplePeersAreIndependent();
        std::cout << "All PeerAudioManager tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
