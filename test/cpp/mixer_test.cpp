#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <memory>
#include <thread>

// Include the production audio_mixer header. The build script compiles this
// test with `-I test/cpp` before `-I android/app/src/main/cpp`, so both this
// test and the production audio_mixer.cpp will pick up the stub jni.h and
// android/log.h from test/cpp/ instead of the real Android NDK headers.
#include "../../android/app/src/main/cpp/audio_mixer.h"

void testMixMinus() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);
    mixer.addDevice(3);

    // 100 frames of audio
    const int numFrames = 100;
    int16_t audio1[numFrames];
    int16_t audio2[numFrames];
    int16_t audio3[numFrames];

    for (int i = 0; i < numFrames; i++) {
        audio1[i] = 100;
        audio2[i] = 200;
        audio3[i] = 300;
    }

    int16_t out1[numFrames];
    int16_t out2[numFrames];
    int16_t out3[numFrames];

    // Production mixer consumes data from ring buffers on read, so we need to
    // re-feed before each getMixedAudioForDevice call.
    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);
    mixer.updateDeviceAudio(3, audio3, numFrames);
    mixer.getMixedAudioForDevice(1, out1, numFrames);

    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);
    mixer.updateDeviceAudio(3, audio3, numFrames);
    mixer.getMixedAudioForDevice(2, out2, numFrames);

    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);
    mixer.updateDeviceAudio(3, audio3, numFrames);
    mixer.getMixedAudioForDevice(3, out3, numFrames);

    // Device 1 should hear (2 + 3) = 200 + 300 = 500
    // Device 2 should hear (1 + 3) = 100 + 300 = 400
    // Device 3 should hear (1 + 2) = 100 + 200 = 300
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 500);
        assert(out2[i] == 400);
        assert(out3[i] == 300);
    }

    std::cout << "Test Mix-Minus: PASSED" << std::endl;
}

void testClipping() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);

    const int numFrames = 10;
    int16_t audio1[numFrames];
    int16_t audio2[numFrames];

    for (int i = 0; i < numFrames; i++) {
        audio1[i] = 30000;
        audio2[i] = 30000;
    }

    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);

    int16_t out1[numFrames];
    mixer.getMixedAudioForDevice(1, out1, numFrames);

    // Device 1 hears Device 2 (30000)
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 30000);
    }

    // Add Device 3 with large audio to force clipping
    mixer.addDevice(3);
    int16_t audio3[numFrames];
    for (int i = 0; i < numFrames; i++) audio3[i] = 30000;

    // Re-feed all devices since the first getMixedAudioForDevice consumed the buffers
    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);
    mixer.updateDeviceAudio(3, audio3, numFrames);

    mixer.getMixedAudioForDevice(1, out1, numFrames);
    // Device 1 hears (2 + 3) = 30000 + 30000 = 60000 (clamped to 32767)
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 32767);
    }

    std::cout << "Test Clipping: PASSED" << std::endl;
}

void testMaxDevices() {
    AudioMixer mixer;
    assert(mixer.addDevice(1) == true);
    assert(mixer.addDevice(2) == true);
    assert(mixer.addDevice(3) == true);
    assert(mixer.addDevice(4) == true);
    assert(mixer.addDevice(5) == true);
    assert(mixer.addDevice(6) == true);
    assert(mixer.addDevice(7) == true);
    assert(mixer.addDevice(8) == true);
    // Production kMaxDevices is 8 (was 3 in the old fork).
    assert(mixer.addDevice(9) == false);
    assert(mixer.getActiveDevices().size() == 8);

    std::cout << "Test Max Devices: PASSED" << std::endl;
}

// Issue #49: a peer whose seq jumps by > kPoisonThreshold is muted until a
// contiguous seq arrives. This is the test the issue's acceptance criteria
// names explicitly: "feed seqs 1, 2, 20 → mixer poisons; feed seq 21 → mixer
// recovers."
void testStuckProducerPrune() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 8;
    int16_t audio[kFrames];
    for (int i = 0; i < kFrames; i++) audio[i] = 1000;

    // Normal flow: contiguous low seqs.
    mixer.onVoiceFrame(1, 1, audio, kFrames);
    assert(!mixer.isPoisoned(1));
    mixer.onVoiceFrame(1, 2, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Big seq jump: 20 - 2 = 18 > kPoisonThreshold (16). Poison.
    mixer.onVoiceFrame(1, 20, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Contiguous next frame recovers (21 - 20 = 1, well within threshold).
    mixer.onVoiceFrame(1, 21, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Stuck Producer Prune: PASSED" << std::endl;
}

// Boundary: a frame exactly at lastSeq + kPoisonThreshold MUST NOT poison
// (the check is strictly `>`, so a 16-frame gap is the largest that still
// passes). One past that does. Locks the threshold semantics so a future
// drift in the constant gets caught.
void testPoisonThresholdBoundary() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {500, 500, 500, 500};

    // Establish lastSeq = 1.
    mixer.onVoiceFrame(1, 1, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // seq = 1 + kPoisonThreshold (= 17): inside the window, must not poison.
    mixer.onVoiceFrame(1, 1 + AudioMixer::kPoisonThreshold, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // seq = 17 + kPoisonThreshold + 1 (= 34): just past the window, must poison.
    mixer.onVoiceFrame(1, 17 + AudioMixer::kPoisonThreshold + 1, audio, kFrames);
    assert(mixer.isPoisoned(1));

    std::cout << "Test Poison Threshold Boundary: PASSED" << std::endl;
}

// Per-peer independence: poisoning one device must not affect another. Real
// rooms can have any subset of peers misbehaving at any given moment.
void testPoisonIsPerPeer() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);

    const int kFrames = 4;
    int16_t audio[kFrames] = {2000, 2000, 2000, 2000};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(2, 1, audio, kFrames);

    // Poison only device 1.
    mixer.onVoiceFrame(1, 100, audio, kFrames);
    assert(mixer.isPoisoned(1));
    assert(!mixer.isPoisoned(2));

    // Continue feeding device 2 normally — it stays healthy.
    mixer.onVoiceFrame(2, 2, audio, kFrames);
    mixer.onVoiceFrame(2, 3, audio, kFrames);
    assert(!mixer.isPoisoned(2));
    assert(mixer.isPoisoned(1));

    std::cout << "Test Poison Is Per-Peer: PASSED" << std::endl;
}

// First-frame edge case: lastSeq starts at 0, so the very first frame must
// always pass regardless of value. The protocol says peers start at seq=1
// but a fresh-session reset can land at any value; we trust the GATT join
// handshake to bound that.
void testFirstFrameAlwaysPasses() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    // First frame at a high seq — should still pass.
    mixer.onVoiceFrame(1, 9999, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Now contiguous seq 10000 is fine (the high seq is the new baseline).
    mixer.onVoiceFrame(1, 10000, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test First Frame Always Passes: PASSED" << std::endl;
}

// Out-of-order or duplicate frames (delta <= 0 against the watermark) must
// be silently dropped: don't poison, don't update lastSeq, don't write audio.
// Without this rule a late-arriving older frame would lower the watermark
// and the *next* in-order frame would look like a giant jump and falsely
// poison the peer.
void testOutOfOrderDoesNotPoisonOrAdvance() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {500, 500, 500, 500};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(1, 5, audio, kFrames);  // watermark = 5

    // Late arrival of an older seq must not poison.
    mixer.onVoiceFrame(1, 3, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Exact duplicate of the watermark must not poison either.
    mixer.onVoiceFrame(1, 5, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // The watermark must still be 5: a small forward jump (5 → 10) stays
    // within threshold. If the OOO frame had lowered it to 3, then 3 → 10
    // would still be within threshold — so prove the invariant a different
    // way: 5 → 22 is exactly 17 ahead and MUST poison; if the OOO frame
    // had lowered the watermark to 3, then 3 → 22 = 19 also poisons, so
    // that's not discriminating. Use the duplicate path instead: jump from
    // 5 by exactly kPoisonThreshold (= 16) → 21, which must NOT poison.
    mixer.onVoiceFrame(1, 5 + AudioMixer::kPoisonThreshold, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Out-of-Order Does Not Poison Or Advance: PASSED" << std::endl;
}

// Recovery rule per [docs/protocol.md] § Voice frame format: "stops mixing
// that peer's stream until the next valid frame arrives." A valid frame is
// any frame within kPoisonThreshold of the (advanced-on-poison) watermark —
// it does NOT have to be strictly seq+1. A non-contiguous-but-within-threshold
// frame after poisoning recovers the peer, and a frame that is *itself* a
// big-jump keeps it poisoned. This test pins both behaviors.
void testRecoveryAcceptsAnyWithinThresholdFrame() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(1, 2, audio, kFrames);

    // Big jump: poison. Watermark advances to 20.
    mixer.onVoiceFrame(1, 20, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Another big jump while poisoned (20 → 40, gap 20 > 16) must keep the
    // peer poisoned and advance the watermark to 40.
    mixer.onVoiceFrame(1, 40, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Non-contiguous-but-within-threshold frame (40 → 50, gap 10 ≤ 16) must
    // recover. (The protocol's "next valid frame" rule, not "next contiguous".)
    mixer.onVoiceFrame(1, 50, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Recovery Accepts Any Within-Threshold Frame: PASSED" << std::endl;
}

// uint32 wraparound. Comparison MUST be wrap-safe: a small forward jump
// across the rollover is normal flow, not a 4-billion-frame gap. Mirrors
// the same fix in production audio_mixer.cpp.
void testSeqWraparoundIsWrapSafe() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    // Seed near rollover.
    mixer.onVoiceFrame(1, 0xFFFFFFF0u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Tiny forward jump straight across uint32 max: gap of 1, must NOT poison.
    mixer.onVoiceFrame(1, 0xFFFFFFF1u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Wrap forward: 0xFFFFFFF1 → 0x0 is exactly +15 modular, within threshold.
    mixer.onVoiceFrame(1, 0x0u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Regression test for the "lastSeq == 0 means unseen" bug CodeRabbit
    // caught on round 2: after legitimately accepting seq=0 (the wrap), the
    // next frame MUST still go through the delta check. With the old sentinel
    // a +0x20 jump would silently bypass poison detection.
    mixer.onVoiceFrame(1, 0x20u, audio, kFrames);  // 0 → 32, gap 32 > 16
    assert(mixer.isPoisoned(1));

    // Recovery within threshold of the new (post-poison) baseline of 0x20.
    mixer.onVoiceFrame(1, 0x21u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // And a real big forward jump still poisons.
    mixer.onVoiceFrame(1, 0x200u, audio, kFrames);  // +0x1DF = 479
    assert(mixer.isPoisoned(1));

    std::cout << "Test Seq Wraparound Is Wrap-Safe: PASSED" << std::endl;
}

// Lifetime regression for issue #99: the global mixer singleton is a
// std::shared_ptr, accessed via std::atomic_load / std::atomic_store. The
// audio callback used to read a bare `AudioMixer*` global that
// `nativeClear` would `delete` concurrently — pure use-after-free.
//
// The fix is two-fold: (1) make the global a shared_ptr so the audio
// thread's *local copy* keeps the mixer alive across the callback, and
// (2) only ever swap the global through the atomic free functions so the
// pointer-to-control-block update is non-tearing. This test pins the
// lifetime contract: an "audio thread" reader holds a strong local
// reference, then a "JNI thread" stores nullptr into the global, and the
// reader still finds its mixer valid for as long as it holds the local.
void testGlobalSharedPtrLifetime() {
    // Static-assert the type so a future regression to a raw pointer fails
    // at compile time, not just at runtime.
    static_assert(
        std::is_same<decltype(g_audioMixer), std::shared_ptr<AudioMixer>>::value,
        "g_audioMixer must be a std::shared_ptr<AudioMixer> for the audio "
        "callback's UAF-safe atomic_load contract");

    // Seed the global.
    auto seeded = std::make_shared<AudioMixer>();
    std::atomic_store(&g_audioMixer, seeded);

    // Simulate the audio callback: take a local owning copy.
    std::shared_ptr<AudioMixer> readerLocal = std::atomic_load(&g_audioMixer);
    assert(readerLocal);
    // Two strong references now: the global, and the reader's local.
    assert(readerLocal.use_count() >= 2);

    // Concurrent "nativeClear" — drop the global ref.
    std::atomic_store(&g_audioMixer, std::shared_ptr<AudioMixer>{});
    // Global is now empty.
    assert(!std::atomic_load(&g_audioMixer));
    // But the reader's local copy is still alive — that is the UAF
    // guarantee. Use the mixer through the local; if the underlying object
    // had been freed this would crash under ASAN.
    readerLocal->addDevice(1);
    readerLocal->removeDevice(1);

    // Drop the local. The original mixer is freed here, deterministically.
    readerLocal.reset();
    // Global already null; the local was the last ref. No leak.

    // Also confirm `seeded` is still our local handle to the same object,
    // and dropping it now finalizes destruction without a double-free.
    seeded.reset();

    std::cout << "Test Global Shared-Ptr Lifetime: PASSED" << std::endl;
}

// Concurrent stress: two threads continuously swap and load the global,
// mirroring the worst case where `nativeClear` and the audio callback
// race indefinitely. Without the atomic free functions a shared_ptr swap
// would tear the control-block pointer; this test would then crash or
// corrupt under ASAN/TSAN. With the atomic ops, the global is always
// either null or a valid mixer, and the reader's local always either
// fails to load or holds a live mixer for the duration of its use.
void testConcurrentSwapAndLoadIsRaceFree() {
    using namespace std::chrono_literals;

    // Seed.
    std::atomic_store(&g_audioMixer, std::make_shared<AudioMixer>());

    std::atomic<bool> stop{false};
    std::atomic<long> readerOps{0};
    std::atomic<long> writerOps{0};

    std::thread reader([&] {
        while (!stop.load(std::memory_order_acquire)) {
            auto local = std::atomic_load(&g_audioMixer);
            if (local) {
                // Touch the mixer's API on read-only paths only — if `local`
                // aliased a freed mixer these would corrupt/crash. We avoid
                // addDevice/removeDevice here because the LOG_TAG print
                // floods CI output (the stress loop can spin millions of
                // iterations under TSAN/ASAN).
                (void)local->isPoisoned(0);
                (void)local->getActiveDevices();
            }
            readerOps.fetch_add(1, std::memory_order_relaxed);
        }
    });

    std::thread writer([&] {
        while (!stop.load(std::memory_order_acquire)) {
            // Alternate: install a fresh mixer, then drop to null.
            std::atomic_store(&g_audioMixer, std::make_shared<AudioMixer>());
            std::atomic_store(&g_audioMixer, std::shared_ptr<AudioMixer>{});
            writerOps.fetch_add(1, std::memory_order_relaxed);
        }
    });

    std::this_thread::sleep_for(100ms);
    stop.store(true, std::memory_order_release);
    reader.join();
    writer.join();

    // Both threads made progress — the test isn't trivially passing on a
    // stalled thread.
    assert(readerOps.load() > 0);
    assert(writerOps.load() > 0);

    // Restore a clean global for any test that runs after us.
    std::atomic_store(&g_audioMixer, std::shared_ptr<AudioMixer>{});

    std::cout << "Test Concurrent Swap And Load Is Race Free: PASSED"
              << std::endl;
}

int main() {
    try {
        testMixMinus();
        testClipping();
        testMaxDevices();
        testStuckProducerPrune();
        testPoisonThresholdBoundary();
        testPoisonIsPerPeer();
        testFirstFrameAlwaysPasses();
        testOutOfOrderDoesNotPoisonOrAdvance();
        testRecoveryAcceptsAnyWithinThresholdFrame();
        testSeqWraparoundIsWrapSafe();
        testGlobalSharedPtrLifetime();
        testConcurrentSwapAndLoadIsRaceFree();
        std::cout << "All C++ Mixer tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
