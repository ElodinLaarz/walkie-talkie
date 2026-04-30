// Host-buildable test for the production resampler. resampler.h is
// header-only and depends only on <cmath> + audio_config.h, so it compiles
// cleanly under host g++ without the Android NDK.
//
// Compile (see scripts/presubmit.sh and .github/workflows/flutter.yml):
//   g++ -std=c++17 -Wall -Wextra -pthread -I android/app/src/main/cpp
//       test/cpp/resampler_test.cpp -o build/cpp_test/resampler_test

#include "resampler.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

// Generate `n` samples of a sine wave at `freqHz` sampled at `sampleRateHz`.
// Amplitude is at half-scale (16384) to leave headroom for filter ringing.
std::vector<int16_t> makeSine(int n, double freqHz, double sampleRateHz,
                              int16_t amplitude = 16384) {
    std::vector<int16_t> v(n);
    for (int i = 0; i < n; ++i) {
        double s = std::sin(2.0 * kPi * freqHz * i / sampleRateHz);
        v[i] = static_cast<int16_t>(amplitude * s);
    }
    return v;
}

double rms(const int16_t* x, int n) {
    if (n == 0) return 0.0;
    double sum = 0.0;
    for (int i = 0; i < n; ++i) {
        double v = x[i] / 32768.0;
        sum += v * v;
    }
    return std::sqrt(sum / n);
}

// Compute peak amplitude over a tail window — first samples include FIR
// warm-up transient, so we measure on samples after the filter has settled.
double peakAfter(const int16_t* x, int n, int skip) {
    double peak = 0.0;
    for (int i = skip; i < n; ++i) {
        double v = std::abs(x[i] / 32768.0);
        if (v > peak) peak = v;
    }
    return peak;
}

void testDecimatorFrameCount() {
    Resampler48to16 r;
    // Steady 960-sample-per-callback feed should produce exactly 320 outputs
    // each call. After warmup the count is exact; we check the second call
    // to skip cold-start phase alignment effects.
    std::vector<int16_t> in(audio_config::kPlayoutFrameSize, 0);
    std::vector<int16_t> out(audio_config::kCodecFrameSize, 0);
    int n1 = r.process(in.data(), static_cast<int>(in.size()), out.data());
    int n2 = r.process(in.data(), static_cast<int>(in.size()), out.data());
    assert(n1 == audio_config::kCodecFrameSize);
    assert(n2 == audio_config::kCodecFrameSize);
    std::cout << "Test Decimator Frame Count: PASSED" << std::endl;
}

void testInterpolatorFrameCount() {
    Resampler16to48 r;
    std::vector<int16_t> in(audio_config::kCodecFrameSize, 0);
    std::vector<int16_t> out(audio_config::kPlayoutFrameSize, 0);
    int n = r.process(in.data(), static_cast<int>(in.size()), out.data());
    assert(n == audio_config::kPlayoutFrameSize);
    std::cout << "Test Interpolator Frame Count: PASSED" << std::endl;
}

// 1 kHz sine at 48 kHz is well below the 7 kHz cutoff. After downsampling
// the RMS amplitude should be ~unchanged (within filter-droop tolerance).
void testDecimatorPassesLowFreq() {
    Resampler48to16 r;
    const int n48 = audio_config::kPlayoutFrameSize * 10;  // 200 ms
    auto in = makeSine(n48, 1000.0, 48000.0);
    std::vector<int16_t> out(n48 / audio_config::kResampleRatio + 16, 0);

    int n16 = r.process(in.data(), n48, out.data());
    assert(n16 > 0);

    // Drop the first ~100 samples to skip FIR warmup, then compare RMS.
    const int kSkip = audio_config::kCodecFrameSize / 2;
    double inputRms = rms(in.data() + kSkip * 3, n48 - kSkip * 3);
    double outputRms = rms(out.data() + kSkip, n16 - kSkip);
    // Expect within 1 dB (ratio 0.89 .. 1.12). The droop at 1 kHz on a
    // Hamming-windowed sinc with 7 kHz cutoff is < 0.2 dB in theory.
    double ratio = outputRms / inputRms;
    if (!(ratio > 0.89 && ratio < 1.12)) {
        std::printf("decimator low-freq pass ratio %.3f out of bounds\n",
                    ratio);
    }
    assert(ratio > 0.89 && ratio < 1.12);
    std::cout << "Test Decimator Passes Low Freq: PASSED" << std::endl;
}

// 12 kHz sine at 48 kHz folds to 4 kHz at 16 kHz output if not filtered —
// without the antialiasing FIR a 12 kHz tone would alias loudly. With the
// FIR, output amplitude must be heavily attenuated. 12 kHz is well above
// the 7 kHz cutoff; transition band ends around 9 kHz, so 12 kHz is firmly
// in the stopband. Hamming gives ~50 dB minimum attenuation; we test a
// loose bound (>20 dB / 10x reduction) to account for FIR ripple and the
// finite test sample.
void testDecimatorRejectsHighFreq() {
    Resampler48to16 r;
    const int n48 = audio_config::kPlayoutFrameSize * 20;  // 400 ms
    auto in = makeSine(n48, 12000.0, 48000.0);
    std::vector<int16_t> out(n48 / audio_config::kResampleRatio + 16, 0);

    int n16 = r.process(in.data(), n48, out.data());
    assert(n16 > 0);

    // Skip the first 100 codec samples for warmup.
    const int kSkip = 100;
    double peakOut = peakAfter(out.data(), n16, kSkip);
    double peakIn = 16384.0 / 32768.0;  // amplitude was 16384

    // Stopband requirement: at least 20 dB rejection.
    if (!(peakOut < peakIn * 0.1)) {
        std::printf("decimator stopband rejection insufficient: peakOut=%.3f peakIn=%.3f\n",
                    peakOut, peakIn);
    }
    assert(peakOut < peakIn * 0.1);
    std::cout << "Test Decimator Rejects High Freq: PASSED" << std::endl;
}

// DC handling: a constant input should produce a constant output (modulo
// small filter-warmup transient). This catches gain-normalization bugs.
void testDecimatorDcGainUnity() {
    Resampler48to16 r;
    const int n48 = audio_config::kPlayoutFrameSize * 5;  // 100 ms
    std::vector<int16_t> in(n48, 10000);  // constant DC
    std::vector<int16_t> out(n48 / audio_config::kResampleRatio + 16, 0);

    int n16 = r.process(in.data(), n48, out.data());
    assert(n16 > 0);

    // After 50 codec samples the FIR is fully warmed up.
    const int kSkip = 50;
    double sum = 0.0;
    int count = 0;
    for (int i = kSkip; i < n16; ++i) {
        sum += out[i];
        ++count;
    }
    double avg = sum / count;
    // Tolerate ±200 LSB to account for floating-point quantization.
    if (!(std::abs(avg - 10000.0) < 200.0)) {
        std::printf("decimator DC avg %.1f out of bounds\n", avg);
    }
    assert(std::abs(avg - 10000.0) < 200.0);
    std::cout << "Test Decimator DC Gain Unity: PASSED" << std::endl;
}

// Round-trip: 1 kHz sine generated at 16 kHz, upsample to 48 kHz, downsample
// back to 16 kHz. The output should match the input within filter-pair
// distortion. This is the primary correctness check for the pair — if either
// resampler is wrong, this test catches it.
void testRoundTripPreservesLowFreq() {
    Resampler16to48 up;
    Resampler48to16 down;
    const int n16 = audio_config::kCodecFrameSize * 20;  // 400 ms
    auto src = makeSine(n16, 1000.0, 16000.0);

    std::vector<int16_t> mid(n16 * audio_config::kResampleRatio, 0);
    int nMid = up.process(src.data(), n16, mid.data());
    assert(nMid == n16 * audio_config::kResampleRatio);

    std::vector<int16_t> dst(n16 + 16, 0);
    int nDst = down.process(mid.data(), nMid, dst.data());
    assert(nDst > 0);

    // Account for combined FIR delays (~half each filter's length, in 16k
    // samples that's ~16 codec samples each way). Skip the first 100 samples
    // and compare RMS — both filters preserve in-band amplitude, so the
    // round-trip RMS should be very close to source RMS.
    const int kSkip = 100;
    double srcRms = rms(src.data() + kSkip, n16 - kSkip);
    double dstRms = rms(dst.data() + kSkip, nDst - kSkip);
    double ratio = dstRms / srcRms;
    if (!(ratio > 0.85 && ratio < 1.18)) {
        std::printf("round-trip ratio %.3f out of bounds (srcRms=%.4f dstRms=%.4f)\n",
                    ratio, srcRms, dstRms);
    }
    assert(ratio > 0.85 && ratio < 1.18);
    std::cout << "Test Round-Trip Preserves Low Freq: PASSED" << std::endl;
}

// Reset() must zero history. After reset, the next call's output should not
// reflect previously-fed audio. We feed a loud impulse, reset, then feed
// silence and confirm the output is silent.
void testResetClearsHistory() {
    Resampler48to16 r;
    std::vector<int16_t> impulse(audio_config::kPlayoutFrameSize, 0);
    impulse[0] = 30000;
    std::vector<int16_t> out1(audio_config::kCodecFrameSize, 0);
    r.process(impulse.data(), static_cast<int>(impulse.size()), out1.data());

    r.reset();

    std::vector<int16_t> silence(audio_config::kPlayoutFrameSize, 0);
    std::vector<int16_t> out2(audio_config::kCodecFrameSize, 0);
    int n = r.process(silence.data(), static_cast<int>(silence.size()),
                      out2.data());
    // Output must be all zeros (history was reset).
    for (int i = 0; i < n; ++i) {
        assert(out2[i] == 0);
    }
    std::cout << "Test Reset Clears History: PASSED" << std::endl;
}

}  // namespace

int main() {
    try {
        testDecimatorFrameCount();
        testInterpolatorFrameCount();
        testDecimatorPassesLowFreq();
        testDecimatorRejectsHighFreq();
        testDecimatorDcGainUnity();
        testRoundTripPreservesLowFreq();
        testResetClearsHistory();
        std::cout << "All Resampler tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
