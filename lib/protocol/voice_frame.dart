import 'dart:typed_data';

/// Minimum L2CAP MTU the voice plane requires per the protocol spec.
/// Hosts and guests must negotiate at least this MTU before opening the
/// L2CAP CoC; a peer that reports a smaller MTU is treated as a
/// version-mismatch and disconnected.
const int kVoiceMtu = 128;

/// Size of the fixed header at the front of every L2CAP voice write.
const int kVoiceHeaderSize = 8;

/// Upper bound on the Opus payload carried by a single voice frame.
///
/// Mirrors the native decode ceiling `audio_config::kMaxOpusPacketSize`
/// (`android/app/src/main/cpp/audio_config.h`) — the size of the buffer the
/// native Opus decoder accepts per frame. A payload larger than this is never
/// produced by our encoder and is rejected on decode so a corrupted or hostile
/// peer cannot push an oversized buffer downstream into the jitter buffer /
/// mixer / native decoder.
const int kMaxVoicePayloadBytes = 4000;

/// An encoded Opus frame as it travels over the L2CAP CoC voice channel.
///
/// Wire layout (big-endian):
///
/// ```text
/// [ seq: uint32 ]  [ senderTsMs: uint32 ]  [ payload: N bytes ]
///   0–3               4–7                    8–(8+N-1)
/// ```
///
/// - `seq` — per-link monotonic counter starting at 1. The host uses it to
///   detect drops: if 16 consecutive values are missing from a peer, the
///   host stops mixing that peer's stream until the next valid frame.
/// - `senderTsMs` — low 32 bits of the sender's **monotonic** clock at encode
///   time (`SystemClock.elapsedRealtime`, ms-since-boot mod 2^32 — NOT
///   wall-clock, so it can't jump under NTP). The receiver pairs it with its
///   own monotonic arrival clock to estimate end-to-end staleness and drop
///   frames whose playback window has already passed (see
///   `PlayoutLagEstimator`).
/// - `payload` — Opus-compressed audio; see `docs/protocol.md § Voice plane`
///   for the recommended codec parameters (24 kHz, mono, 20 ms, 32 kbps).
class VoiceFrame {
  final int seq;
  final int senderTsMs;
  final Uint8List payload;

  VoiceFrame({
    required this.seq,
    required this.senderTsMs,
    required this.payload,
  }) {
    RangeError.checkValueInInterval(seq, 0, 0xFFFFFFFF, 'seq');
    RangeError.checkValueInInterval(senderTsMs, 0, 0xFFFFFFFF, 'senderTsMs');
    // Opus always emits at least one byte, so a header-only frame is invalid.
    // decode() rejects the empty case on the wire; enforce the same invariant
    // at construction so the failure is loud + local instead of a silent
    // one-directional voice drop at the receiving peer.
    if (payload.isEmpty) {
      throw ArgumentError.value(
        payload,
        'payload',
        'VoiceFrame payload must be non-empty — Opus always emits at least one byte',
      );
    }
    RangeError.checkValueInInterval(
      payload.length,
      1,
      kMaxVoicePayloadBytes,
      'payload.length',
    );
  }

  /// Serialises to the 8-byte header followed by the Opus payload.
  Uint8List encode() {
    final out = Uint8List(kVoiceHeaderSize + payload.length);
    final view = ByteData.sublistView(out);
    view.setUint32(0, seq, Endian.big);
    view.setUint32(4, senderTsMs, Endian.big);
    out.setRange(kVoiceHeaderSize, kVoiceHeaderSize + payload.length, payload);
    return out;
  }

  /// Parses a single L2CAP write into a [VoiceFrame].
  ///
  /// Throws [FormatException] if:
  /// - [bytes] is shorter than [kVoiceHeaderSize] — the write is too small
  ///   to carry the mandatory header.
  /// - [bytes] contains no payload after the header — a zero-length Opus
  ///   frame is not valid; the codec always emits at least one byte.
  /// - the payload exceeds [kMaxVoicePayloadBytes] — larger than any frame our
  ///   encoder emits and larger than the native decoder accepts; rejected so a
  ///   hostile/corrupt peer cannot push an oversized buffer downstream.
  ///
  /// Receivers catch [FormatException] and drop the frame; the L2CAP CoC
  /// stays open (same policy as the GATT control-plane).
  factory VoiceFrame.decode(Uint8List bytes) {
    if (bytes.length < kVoiceHeaderSize) {
      throw FormatException(
        'VoiceFrame too short: ${bytes.length} bytes '
        '(header requires $kVoiceHeaderSize)',
      );
    }
    final view = ByteData.sublistView(bytes);
    final seq = view.getUint32(0, Endian.big);
    final senderTsMs = view.getUint32(4, Endian.big);
    final payloadLen = bytes.length - kVoiceHeaderSize;
    if (payloadLen == 0) {
      throw const FormatException(
        'VoiceFrame has no payload — Opus always emits at least one byte',
      );
    }
    if (payloadLen > kMaxVoicePayloadBytes) {
      throw FormatException(
        'VoiceFrame payload too large: $payloadLen bytes '
        '(max $kMaxVoicePayloadBytes)',
      );
    }
    return VoiceFrame(
      seq: seq,
      senderTsMs: senderTsMs,
      payload: Uint8List.fromList(bytes.sublist(kVoiceHeaderSize)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoiceFrame &&
          seq == other.seq &&
          senderTsMs == other.senderTsMs &&
          _bytesEqual(payload, other.payload);

  @override
  int get hashCode => Object.hash(seq, senderTsMs, Object.hashAll(payload));

  @override
  String toString() =>
      'VoiceFrame(seq=$seq, senderTsMs=$senderTsMs, payload=${payload.length}B)';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
