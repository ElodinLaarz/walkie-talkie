import 'dart:convert';
import 'dart:typed_data';

/// Maximum bytes per wire fragment (full header + payload) that the v1
/// protocol emits. This is the *fragment-size* ceiling, not an ATT MTU:
/// callers with a negotiated ATT MTU of N should pass `min(N - 3, 247)` to
/// [encodeFragments] (3 bytes go to the ATT write/notify opcode + handle).
/// The negotiation itself lives in the platform layer (see
/// `docs/protocol.md` § GATT service); the framing code only sees byte
/// buffers sized at or below this ceiling. Receivers honour each
/// fragment's `total_len` + `fragment_idx` header and never assume a
/// particular per-fragment size.
const int kMaxFragmentSize = 247;

/// Smallest fragment-size budget the encoder will honour, matching the
/// BLE default GATT MTU of 23 bytes that two devices are guaranteed to
/// support before any negotiation (see `docs/protocol.md` § GATT
/// service). At that floor the payload budget is `23 - 4 = 19` bytes per
/// fragment. The encoder rejects anything smaller as a caller bug rather
/// than silently producing fragments the link can't carry.
const int kMinFragmentSize = 23;

/// Fragment header in front of every chunk on the wire.
///
/// ```text
/// [ flags=0x00  total_len_hi  total_len_lo  fragment_idx ]  <up-to-243 bytes>
/// ```
const int kFragmentHeaderSize = 4;

/// Maximum payload bytes carried by a single fragment.
const int kMaxFragmentPayloadSize = kMaxFragmentSize - kFragmentHeaderSize;

/// Hard cap on the size of any one logical message — 4 KiB / 17 fragments at
/// the negotiated MTU. Anything larger is a protocol error: the roster's
/// worst-case shape (12 peers, padded names, BT device strings) sits well
/// inside this margin.
const int kMaxMessageSize = 4096;

/// `total_len` is encoded as a big-endian uint16; an 0xFFFF cap is the
/// implicit ceiling of that field. A receiver computing
/// `(hi << 8) | lo` will mask anything wider, so the encoder fails fast
/// instead of letting a length overflow silently.
const int kMaxEncodableLength = 0xFFFF;

/// `fragment_idx` is a uint8 on the wire (offset 3 of every fragment
/// header); 256 fragments is the absolute ceiling regardless of any
/// other cap. With the v1 [kMaxMessageSize] of 4 KiB and 243-byte
/// payloads we land at ~17 fragments — well below this — but a future
/// cap raise must not silently wrap to a 1-byte index.
const int kMaxFragmentCount = 256;

/// Reserved flag byte at offset 0 of every fragment header. v1 always emits
/// `0x00`; receivers MUST drop fragments whose flag byte they don't
/// recognize so a future bit (e.g. compression, signing) doesn't get
/// silently misinterpreted by an older guest.
const int kFragmentFlagsV1 = 0x00;

/// A length-prefixed JSON message split into one or more fragments suitable
/// for writing to the GATT REQUEST/RESPONSE characteristic.
///
/// Each fragment is an independent BLE write — the receiver reassembles them
/// using the `total_len` + `fragment_idx` header carried on every fragment.
///
/// [maxFragmentSize] is the per-write byte ceiling (full fragment buffer
/// = 4-byte header + payload) and defaults to [kMaxFragmentSize]. Callers
/// with a negotiated ATT MTU should pass `min(mtu - 3, kMaxFragmentSize)`
/// here so the encoder doesn't emit fragments the link will refragment
/// unpredictably. Must be in the closed range
/// `[kMinFragmentSize, kMaxFragmentSize]`; values outside throw
/// `ArgumentError`.
List<Uint8List> encodeFragments(
  String json, {
  int maxFragmentSize = kMaxFragmentSize,
}) {
  if (maxFragmentSize < kMinFragmentSize ||
      maxFragmentSize > kMaxFragmentSize) {
    throw ArgumentError.value(
      maxFragmentSize,
      'maxFragmentSize',
      'must be in [$kMinFragmentSize, $kMaxFragmentSize]',
    );
  }
  final fragmentPayloadSize = maxFragmentSize - kFragmentHeaderSize;

  final bytes = utf8.encode(json);
  if (bytes.length > kMaxMessageSize) {
    throw FormatException(
      'Message too large for v1 framing: ${bytes.length} bytes '
      '(cap: $kMaxMessageSize)',
    );
  }
  // Defensive: kMaxMessageSize is well below the wire's uint16 ceiling, but
  // the check at the wire boundary protects us if a future patch raises
  // the v1 cap and forgets to widen `total_len`.
  if (bytes.length > kMaxEncodableLength) {
    throw FormatException(
      'Message length exceeds 16-bit wire encoding: ${bytes.length}',
    );
  }

  final totalLen = bytes.length;
  final fragmentCount = totalLen == 0
      ? 1
      : (totalLen + fragmentPayloadSize - 1) ~/ fragmentPayloadSize;
  // With the smallest legal MTU (23 → 19-byte payload) and the v1 4 KiB
  // message cap, the worst case is ~216 fragments — under the uint8
  // `fragment_idx` ceiling. Recheck anyway: silently masking `i` to 8 bits
  // would produce duplicate fragment indices on the wire and a
  // reassembler that confidently stitches together garbage.
  if (fragmentCount > kMaxFragmentCount) {
    throw FormatException(
      'Message requires $fragmentCount fragments; fragment_idx is uint8 '
      '(cap: $kMaxFragmentCount)',
    );
  }

  final fragments = <Uint8List>[];
  for (int i = 0; i < fragmentCount; i++) {
    final start = i * fragmentPayloadSize;
    final end =
        (start + fragmentPayloadSize) < totalLen
            ? start + fragmentPayloadSize
            : totalLen;
    final payloadLen = end - start;

    final fragment = Uint8List(kFragmentHeaderSize + payloadLen)
      ..[0] = kFragmentFlagsV1
      ..[1] = (totalLen >> 8) & 0xFF
      ..[2] = totalLen & 0xFF
      ..[3] = i;
    if (payloadLen > 0) {
      fragment.setRange(
        kFragmentHeaderSize,
        kFragmentHeaderSize + payloadLen,
        bytes,
        start,
      );
    }
    fragments.add(fragment);
  }
  return fragments;
}

/// Errors emitted by the [FragmentReassembler]. These are recoverable at
/// the link level — the protocol's policy is to drop the offending fragment
/// (and the in-flight buffer for that message) and keep the connection up.
sealed class FragmentError implements Exception {
  final String message;
  const FragmentError(this.message);
  @override
  String toString() => 'FragmentError: $message';
}

/// Fragment was shorter than the 4-byte header, or its flags byte isn't
/// recognized in this protocol version.
class MalformedFragment extends FragmentError {
  const MalformedFragment(super.message);
}

/// `total_len` exceeded the v1 message cap, or contradicted a previously
/// seen fragment from the same in-flight message.
class InconsistentFragment extends FragmentError {
  const InconsistentFragment(super.message);
}

/// Fragment arrived out of order, or `fragment_idx` exceeded what
/// `total_len` requires.
class UnexpectedFragmentIndex extends FragmentError {
  const UnexpectedFragmentIndex(super.message);
}

/// Reassembles fragments into complete JSON messages.
///
/// Single-producer, single-consumer: each instance tracks the in-flight
/// message for one logical sender (one GATT characteristic on one
/// connection). v1 fragments arrive in order — every reassembler reset
/// throws [UnexpectedFragmentIndex] rather than silently buffering
/// out-of-order data, so a misbehaving peer surfaces loudly instead of
/// poisoning the next message.
///
/// Usage:
///
/// ```dart
/// final r = FragmentReassembler();
/// for (final frag in incomingFragments) {
///   final complete = r.feed(frag);
///   if (complete != null) handleMessage(complete);
/// }
/// ```
class FragmentReassembler {
  int? _expectedTotalLen;
  int _nextIdx = 0;
  // Default-mode (copying) BytesBuilder: BLE callers commonly reuse
  // packet buffers, so a non-copying view would corrupt our reassembly
  // state out from under us. The copy is ≤4 KiB per message — cheap.
  final BytesBuilder _buffer = BytesBuilder();

  /// Reset to an empty in-flight message. Useful when the underlying link
  /// drops mid-message and the receiver needs to discard the partial buffer
  /// before the next fragment arrives.
  void reset() {
    _expectedTotalLen = null;
    _nextIdx = 0;
    _buffer.clear();
  }

  /// Feed one fragment. Returns the complete UTF-8 JSON string when the
  /// fragment closes a message, or `null` while the message is still
  /// in-flight.
  ///
  /// Throws [FragmentError] subtypes on protocol violations. The caller
  /// catches and drops; the reassembler is internally reset so the next
  /// `feed` starts a fresh message.
  String? feed(Uint8List fragment) {
    if (fragment.length < kFragmentHeaderSize) {
      reset();
      throw MalformedFragment(
        'Fragment shorter than header: ${fragment.length} bytes',
      );
    }
    final flags = fragment[0];
    if (flags != kFragmentFlagsV1) {
      reset();
      throw MalformedFragment(
        'Unknown fragment flags byte: 0x${flags.toRadixString(16)}',
      );
    }
    final totalLen = (fragment[1] << 8) | fragment[2];
    final idx = fragment[3];

    if (totalLen > kMaxMessageSize) {
      reset();
      throw InconsistentFragment(
        'Declared total_len $totalLen exceeds cap $kMaxMessageSize',
      );
    }

    final expected = _expectedTotalLen;
    if (expected == null) {
      // First fragment — index must be zero, total_len anchors the buffer.
      if (idx != 0) {
        reset();
        throw UnexpectedFragmentIndex(
          'Expected fragment_idx 0 to start a message, got $idx',
        );
      }
      _expectedTotalLen = totalLen;
    } else {
      if (totalLen != expected) {
        reset();
        throw InconsistentFragment(
          'total_len $totalLen contradicts in-flight $expected',
        );
      }
      if (idx != _nextIdx) {
        reset();
        throw UnexpectedFragmentIndex(
          'Expected fragment_idx $_nextIdx, got $idx',
        );
      }
    }

    final payloadLen = fragment.length - kFragmentHeaderSize;
    final remaining = totalLen - _buffer.length;
    if (payloadLen > remaining) {
      reset();
      throw InconsistentFragment(
        'Fragment payload $payloadLen bytes exceeds remaining $remaining',
      );
    }
    if (payloadLen > 0) {
      _buffer.add(
        Uint8List.sublistView(fragment, kFragmentHeaderSize),
      );
    }
    _nextIdx++;

    if (_buffer.length == totalLen) {
      final out = _buffer.toBytes();
      reset();
      // utf8.decode throws FormatException on bad bytes; let it propagate
      // — the caller treats invalid UTF-8 the same as any other dropped
      // message.
      return utf8.decode(out);
    }
    return null;
  }
}
