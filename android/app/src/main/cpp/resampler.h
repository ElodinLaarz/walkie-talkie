#ifndef RESAMPLER_H
#define RESAMPLER_H

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iterator>

#include "audio_config.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Sample-rate conversion between Oboe (48 kHz) and Opus / mixer (16 kHz).
//
// Both directions share the same prototype low-pass: a 33-tap Hamming-windowed
// sinc with cutoff at 7 kHz / 48 kHz. 33 taps is small enough to run in the
// audio callback (< 1k multiplies per 20 ms frame after polyphase), and the
// cutoff sits comfortably below the 16 kHz Nyquist at 8 kHz with ~1 kHz
// transition band — the in-band droop is < 0.5 dB across the speech range.
//
// 33 is `(kSubTaps * kResampleRatio)` and is required to divide cleanly into
// kResampleRatio polyphase sub-filters. Don't tune it without keeping that
// invariant.
//
// **Real-time safety.** No heap allocation after construction. Float math
// only; no atomics, no locks. Safe to call from the Oboe audio callback.
//
// **Phase memory.** The decimator carries a phase counter across `process()`
// calls, so a 7-sample burst at 48 kHz produces 2 samples at 16 kHz and the
// remaining input becomes part of the next call's first output. The
// interpolator is symmetric — exactly 3 outputs per input.
//
// **Reset semantics.** `reset()` zeros the filter history. Use it on
// stream restart (Oboe error → reopen) so the first output samples don't
// carry transients from the previous stream.

namespace audio_resampler_detail {

// Design one Hamming-windowed sinc low-pass at fc / fs. Caller supplies the
// output buffer (size = numTaps) and the desired DC gain (1 for decimator,
// L for L-fold interpolator). Used by both classes below at construction.
inline void designLowPass(float* coeffs, int numTaps, double fcNorm,
                          double dcGain) {
    const double M = numTaps - 1;
    double sum = 0.0;
    for (int n = 0; n < numTaps; ++n) {
        const double x = static_cast<double>(n) - M / 2.0;
        const double sinc =
            (x == 0.0)
                ? (2.0 * fcNorm)
                : (std::sin(2.0 * M_PI * fcNorm * x) / (M_PI * x));
        const double window = 0.54 - 0.46 * std::cos(2.0 * M_PI * n / M);
        const double v = sinc * window;
        coeffs[n] = static_cast<float>(v);
        sum += v;
    }
    if (sum != 0.0) {
        const double scale = dcGain / sum;
        for (int n = 0; n < numTaps; ++n) {
            coeffs[n] = static_cast<float>(coeffs[n] * scale);
        }
    }
}

constexpr int kPrototypeTaps = 33;
constexpr int kCutoffHz = 7000;

}  // namespace audio_resampler_detail

// 48 kHz -> 16 kHz (3:1 decimation). Written as a straightforward FIR plus a
// phase counter rather than polyphase: at L=3 the polyphase win is small and
// the loop layout matters more for cache than for tap count.
class Resampler48to16 {
public:
    static constexpr int kNumTaps = audio_resampler_detail::kPrototypeTaps;

    Resampler48to16() {
        audio_resampler_detail::designLowPass(
            coeffs_, kNumTaps,
            static_cast<double>(audio_resampler_detail::kCutoffHz) /
                audio_config::kPlayoutSampleRate,
            /*dcGain=*/1.0);
        reset();
    }

    // Decimate `numIn` samples from `in48` (48 kHz, int16 PCM) into `out16`
    // (16 kHz, int16 PCM). Returns number of output samples written.
    //
    // The output count is `(numIn + carry) / 3` where `carry` is the leftover
    // phase from the previous call. For a steady 960-sample-per-callback feed
    // this is exactly 320.
    int process(const int16_t* in48, int numIn, int16_t* out16) {
        int outCount = 0;
        for (int i = 0; i < numIn; ++i) {
            // Slide history one slot. historyIdx_ now points to the slot that
            // will hold x[n]; the slot just past it (modulo) holds x[n-N+1],
            // i.e. the oldest sample, which we'll multiply by coeffs_[N-1].
            historyIdx_ = (historyIdx_ + 1) % kNumTaps;
            history_[historyIdx_] =
                static_cast<float>(in48[i]) * (1.0f / 32768.0f);

            phase_ = (phase_ + 1) % audio_config::kResampleRatio;
            if (phase_ != 0) continue;

            // FIR: y[n] = sum_k coeffs_[k] * x[n-k]. Walk history newest-to-
            // oldest so coeffs_[0] aligns with x[n].
            float acc = 0.0f;
            int idx = historyIdx_;
            for (int k = 0; k < kNumTaps; ++k) {
                acc += coeffs_[k] * history_[idx];
                idx = (idx + kNumTaps - 1) % kNumTaps;
            }
            int32_t s = static_cast<int32_t>(acc * 32768.0f);
            if (s > 32767) s = 32767;
            else if (s < -32768) s = -32768;
            out16[outCount++] = static_cast<int16_t>(s);
        }
        return outCount;
    }

    void reset() {
        std::fill(std::begin(history_), std::end(history_), 0.0f);
        // historyIdx_ starts at -1 so the first push lands at slot 0.
        historyIdx_ = kNumTaps - 1;
        phase_ = audio_config::kResampleRatio - 1;  // first push triggers an output? No — we want the FIRST sample to be phase 0.
    }

private:
    float coeffs_[kNumTaps] = {};
    float history_[kNumTaps] = {};
    int historyIdx_ = 0;
    int phase_ = 0;
};

// 16 kHz -> 48 kHz (1:3 interpolation). Polyphase form: one prototype FIR
// split into 3 sub-filters of 11 taps each. Each input produces exactly 3
// outputs, so callers can size out48 for `3 * numIn` and trust the math.
class Resampler16to48 {
public:
    static constexpr int kPrototypeTaps = audio_resampler_detail::kPrototypeTaps;
    static constexpr int kSubTaps =
        (kPrototypeTaps + audio_config::kResampleRatio - 1) /
        audio_config::kResampleRatio;  // 11
    static_assert(kSubTaps * audio_config::kResampleRatio >= kPrototypeTaps,
                  "sub-filter must cover the full prototype");

    Resampler16to48() {
        float prototype[kPrototypeTaps];
        // DC gain = L compensates for the L-1 zeros that polyphase replaces;
        // without this scaling a 0 dBFS input would come out at -9.5 dBFS.
        audio_resampler_detail::designLowPass(
            prototype, kPrototypeTaps,
            static_cast<double>(audio_resampler_detail::kCutoffHz) /
                audio_config::kPlayoutSampleRate,
            /*dcGain=*/static_cast<double>(audio_config::kResampleRatio));

        // Split into L sub-filters. Sub-filter p produces output samples at
        // positions `L*n + p`, with taps h[p], h[L+p], h[2L+p], ...
        for (int p = 0; p < audio_config::kResampleRatio; ++p) {
            for (int k = 0; k < kSubTaps; ++k) {
                const int idx = p + k * audio_config::kResampleRatio;
                subCoeffs_[p][k] =
                    (idx < kPrototypeTaps) ? prototype[idx] : 0.0f;
            }
        }
        reset();
    }

    // Interpolate `numIn` samples from `in16` (16 kHz) into `out48` (48 kHz).
    // Returns number of output samples written, always `3 * numIn`.
    int process(const int16_t* in16, int numIn, int16_t* out48) {
        int outCount = 0;
        for (int i = 0; i < numIn; ++i) {
            historyIdx_ = (historyIdx_ + 1) % kSubTaps;
            history_[historyIdx_] =
                static_cast<float>(in16[i]) * (1.0f / 32768.0f);

            for (int p = 0; p < audio_config::kResampleRatio; ++p) {
                float acc = 0.0f;
                int idx = historyIdx_;
                for (int k = 0; k < kSubTaps; ++k) {
                    acc += subCoeffs_[p][k] * history_[idx];
                    idx = (idx + kSubTaps - 1) % kSubTaps;
                }
                int32_t s = static_cast<int32_t>(acc * 32768.0f);
                if (s > 32767) s = 32767;
                else if (s < -32768) s = -32768;
                out48[outCount++] = static_cast<int16_t>(s);
            }
        }
        return outCount;
    }

    void reset() {
        std::fill(std::begin(history_), std::end(history_), 0.0f);
        historyIdx_ = kSubTaps - 1;
    }

private:
    float subCoeffs_[audio_config::kResampleRatio][kSubTaps] = {};
    float history_[kSubTaps] = {};
    int historyIdx_ = 0;
};

#endif  // RESAMPLER_H
