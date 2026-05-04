#ifndef VAD_DETECTOR_H
#define VAD_DETECTOR_H

#include <cstdint>
#include <optional>

// Voice-activity detector with two-sided hysteresis.
//
// The detector tracks "above threshold" and "below threshold" frame counts
// and emits rising/falling edges only after the configured hold-off windows
// have elapsed. This prevents rapid UI flicker at threshold boundaries.
//
// Typical usage (48 kHz, one Oboe callback per call):
//
//   VadDetector vad(48000);
//   if (auto edge = vad.update(rms > kThreshold, numFrames)) {
//       emitTalkingEvent(*edge);  // true = started talking, false = stopped
//   }
//
// Thread safety: not thread-safe; must be called from a single audio thread.
struct VadDetector {
    // Default RMS threshold (-40 dBFS). Scales against normalised int16
    // samples (divided by 32768).
    static constexpr double kDefaultThreshold = 0.01;

    // Hysteresis windows matching the original inline constants in
    // audio_engine.cpp. Rise (on) is intentionally shorter than fall (off) so
    // the UI responds quickly to speech but does not chatter on breath-pauses.
    static constexpr int32_t kOnHysteresisMs  = 100;
    static constexpr int32_t kOffHysteresisMs = 300;

    // `sampleRate` is the rate of the audio stream feeding this detector
    // (typically 48000 for Oboe). `threshold` is the RMS level above which
    // a frame is considered "loud".
    explicit VadDetector(int32_t sampleRate,
                         double threshold = kDefaultThreshold)
        : sampleRate_(sampleRate),
          threshold_(threshold),
          onFrames_((sampleRate * kOnHysteresisMs) / 1000),
          offFrames_((sampleRate * kOffHysteresisMs) / 1000) {}

    // Feed one audio callback's worth of signal. `aboveThreshold` is true
    // when the RMS of this burst exceeds the threshold; `numFrames` is the
    // sample count of the burst.
    //
    // Returns the new talking state if a VAD edge was crossed, or nullopt if
    // the state did not change this burst.
    std::optional<bool> update(bool aboveThreshold, int32_t numFrames) {
        if (aboveThreshold) {
            aboveFrames_ += numFrames;
            belowFrames_ = 0;
            if (!talking_ && aboveFrames_ >= onFrames_) {
                talking_ = true;
                return true;
            }
        } else {
            belowFrames_ += numFrames;
            aboveFrames_ = 0;
            if (talking_ && belowFrames_ >= offFrames_) {
                talking_ = false;
                return false;
            }
        }
        return std::nullopt;
    }

    // Current talking state (true after a rising edge, false after a falling
    // edge or before the first rising edge).
    bool talking() const { return talking_; }

    // Returns the RMS threshold this detector was constructed with.
    double threshold() const { return threshold_; }

    // Reset state to silent as if the detector were freshly constructed.
    // Useful for engine restarts so stale hysteresis counts do not carry over.
    void reset() {
        talking_     = false;
        aboveFrames_ = 0;
        belowFrames_ = 0;
    }

private:
    const int32_t sampleRate_;
    const double  threshold_;
    const int32_t onFrames_;   // frames of above-threshold signal to confirm talking
    const int32_t offFrames_;  // frames of below-threshold signal to confirm silence

    bool    talking_     = false;
    int32_t aboveFrames_ = 0;
    int32_t belowFrames_ = 0;
};

#endif  // VAD_DETECTOR_H
