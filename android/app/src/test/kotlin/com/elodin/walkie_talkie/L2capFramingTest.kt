package com.elodin.walkie_talkie

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Unit tests for the L2CAP voice transport framing helpers and writer-thread
 * queue. These cover the correctness contracts called out in issue #101 — they
 * don't (and can't) exercise the actual Bluetooth socket path, but every
 * behaviour that can be tested against an in-memory stream is.
 */
class L2capFramingTest {

    /** Round-trip a single frame through writeFramed / readFramed. */
    @Test
    fun roundTripSingleFrame() {
        val payload = ByteArray(40) { it.toByte() }
        val out = ByteArrayOutputStream()
        writeFramed(out, payload)

        val input = DataInputStream(ByteArrayInputStream(out.toByteArray()))
        val read = readFramed(input)
        assertArrayEquals(payload, read)
        // Stream is now at EOF.
        assertNull(readFramed(input))
    }

    /**
     * Two frames written back-to-back must come out as two distinct frames
     * even though the receiving InputStream might return them in a single
     * read() — the whole point of the length prefix.
     */
    @Test
    fun framesDoNotMergeAcrossReads() {
        val a = ByteArray(64) { it.toByte() }
        val b = ByteArray(96) { (it + 100).toByte() }
        val out = ByteArrayOutputStream()
        writeFramed(out, a)
        writeFramed(out, b)

        // Wrap as a single InputStream — typical receive-side scenario where
        // both writes coalesce into one TCP-style read.
        val input = DataInputStream(ByteArrayInputStream(out.toByteArray()))
        assertArrayEquals(a, readFramed(input))
        assertArrayEquals(b, readFramed(input))
        assertNull(readFramed(input))
    }

    /** Clean EOF *between* frames returns null without throwing. */
    @Test
    fun cleanEofBetweenFramesReturnsNull() {
        val input = DataInputStream(ByteArrayInputStream(ByteArray(0)))
        assertNull(readFramed(input))
    }

    /** EOF mid-prefix is an error — partial header is corrupt. */
    @Test
    fun midPrefixEofThrows() {
        val input = DataInputStream(ByteArrayInputStream(byteArrayOf(0x00)))
        try {
            readFramed(input)
            fail("expected IOException")
        } catch (_: IOException) { /* expected */ }
    }

    /** Zero-length frames are rejected — Opus always emits >0 bytes. */
    @Test
    fun zeroLengthFrameThrows() {
        val input = DataInputStream(ByteArrayInputStream(byteArrayOf(0x00, 0x00)))
        try {
            readFramed(input)
            fail("expected IOException")
        } catch (_: IOException) { /* expected */ }
    }

    /**
     * A length prefix above MAX_FRAME_SIZE must throw rather than allocate
     * gigabytes — defends against a malformed peer.
     */
    @Test
    fun oversizedLengthPrefixThrows() {
        val len = L2capVoiceTransport.MAX_FRAME_SIZE + 1
        val bytes = byteArrayOf(((len ushr 8) and 0xff).toByte(), (len and 0xff).toByte())
        val input = DataInputStream(ByteArrayInputStream(bytes))
        try {
            readFramed(input)
            fail("expected IOException")
        } catch (_: IOException) { /* expected */ }
    }

    /**
     * writeFramed rejects a frame larger than MAX_FRAME_SIZE — symmetric
     * with the reader's check so misbehaving senders get caught early.
     */
    @Test
    fun oversizedWriteThrows() {
        val out = ByteArrayOutputStream()
        try {
            writeFramed(out, ByteArray(L2capVoiceTransport.MAX_FRAME_SIZE + 1))
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) { /* expected */ }
    }

    /**
     * The contention test that issue #101 calls out as the missing acceptance
     * criterion: many concurrent producers all push frames into one queue,
     * a single drainer thread writes them framed onto a pipe, and the
     * reader on the other end of the pipe pulls them back out with
     * readFramed. The writer is the only party that touches the stream,
     * which is what eliminates torn frames.
     */
    @Test
    fun multiProducerSingleWriterNeverTearsAFrame() {
        val producers = 8
        val framesPerProducer = 200
        val queue = LinkedBlockingQueue<ByteArray>(L2capVoiceTransport.SEND_QUEUE_CAPACITY * 4)
        // Sentinel — empty array — terminates the writer.
        val SENTINEL = ByteArray(0)

        val pipeOut = PipedOutputStream()
        val pipeIn = PipedInputStream(pipeOut, 4096)
        val readerInput = DataInputStream(pipeIn)

        // Writer drains queue -> pipe.
        val writer = Thread {
            try {
                while (true) {
                    val frame = queue.take()
                    if (frame === SENTINEL) break
                    writeFramed(pipeOut, frame)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                pipeOut.close()
            }
        }.apply { isDaemon = true; start() }

        val totalExpected = producers * framesPerProducer
        val rng = Random(42)

        // Reader collects frames.
        val readFrames = mutableListOf<ByteArray>()
        val reader = Thread {
            try {
                while (readFrames.size < totalExpected) {
                    val f = readFramed(readerInput) ?: break
                    synchronized(readFrames) { readFrames.add(f) }
                }
            } catch (_: IOException) { /* pipe closed */ }
        }.apply { isDaemon = true; start() }

        // Producers pump distinct payloads.
        val producerCount = AtomicInteger(producers)
        repeat(producers) { p ->
            Thread {
                try {
                    repeat(framesPerProducer) { i ->
                        // Length varies so a torn frame would surface as a
                        // wrong size in the assertion below.
                        val size = 8 + rng.nextInt(120) // VoiceFrame header + payload
                        val frame = ByteArray(size)
                        // Encode a producer ID + sequence so we can verify
                        // ordering inside each producer.
                        frame[0] = p.toByte()
                        frame[1] = (i ushr 24).toByte()
                        frame[2] = (i ushr 16).toByte()
                        frame[3] = (i ushr 8).toByte()
                        frame[4] = (i and 0xff).toByte()
                        for (b in 5 until size) frame[b] = ((p * 31 + i + b) and 0xff).toByte()
                        // Block on full queue — we want the test to exercise
                        // backpressure, not lossy drop-oldest behaviour.
                        queue.put(frame)
                    }
                } finally {
                    if (producerCount.decrementAndGet() == 0) queue.put(SENTINEL)
                }
            }.apply { isDaemon = true; start() }
        }

        // Reader should finish within a generous timeout.
        reader.join(TimeUnit.SECONDS.toMillis(10))
        writer.join(TimeUnit.SECONDS.toMillis(2))
        assertTrue("reader should have terminated", !reader.isAlive)
        assertTrue("writer should have terminated", !writer.isAlive)
        assertEquals(totalExpected, readFrames.size)

        // Per producer, the embedded sequence numbers must be strictly
        // monotonic — anything else means a frame got torn or merged.
        val perProducer = Array(producers) { mutableListOf<Int>() }
        for (frame in readFrames) {
            val p = frame[0].toInt() and 0xff
            val seq = ((frame[1].toInt() and 0xff) shl 24) or
                ((frame[2].toInt() and 0xff) shl 16) or
                ((frame[3].toInt() and 0xff) shl 8) or
                (frame[4].toInt() and 0xff)
            perProducer[p].add(seq)
        }
        for (p in 0 until producers) {
            val seqs = perProducer[p]
            assertEquals("producer $p missing frames", framesPerProducer, seqs.size)
            for (i in 0 until framesPerProducer) {
                assertEquals("producer $p out-of-order frame at index $i", i, seqs[i])
            }
        }
    }
}
