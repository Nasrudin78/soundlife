package com.example.soundlife

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.tan

/**
 * Sonoridad integrada (LUFS) según EBU R128 / ITU-R BS.1770-4: ponderación K, bloques de 400 ms con
 * solapamiento del 75 % y puertas absoluta (−70 LUFS) y relativa (−10 LU).
 *
 * Los audios de Sound and Life duran hasta 70 min, así que en ficheros largos se analizan
 * [WINDOWS] ventanas de [WINDOW_SECONDS] s repartidas por todo el fichero en lugar del fichero entero.
 */
object LoudnessMeter {
    private const val WINDOWS = 20
    private const val WINDOW_SECONDS = 15.0
    private const val SETTLE_SECONDS = 0.5 // se descarta el arranque de los filtros en cada ventana
    private const val TIMEOUT_US = 10_000L
    private const val WINDOW_DEADLINE_MS = 20_000L // un decodificador atascado no bloquea para siempre

    fun measure(path: String): Double? = measureWav(path) ?: measureDecoded(path)

    /** Ventanas (inicio, duración) en segundos que se analizan de un audio de [durationS] segundos. */
    private fun windows(durationS: Double): List<Pair<Double, Double>> =
        if (durationS <= WINDOWS * WINDOW_SECONDS || durationS <= 0) {
            listOf(0.0 to (if (durationS > 0) durationS else Double.MAX_VALUE))
        } else {
            (0 until WINDOWS).map { k ->
                val center = durationS * (k + 0.5) / WINDOWS
                val start = (center - WINDOW_SECONDS / 2).coerceIn(0.0, durationS - WINDOW_SECONDS)
                start to WINDOW_SECONDS
            }
        }

    /** Acumula la energía ponderada de los fotogramas de una ventana en bloques de 400 ms (pasos de 100 ms). */
    private class WindowAccumulator(rate: Int, lengthS: Double) {
        private val targetFrames = if (lengthS == Double.MAX_VALUE) Long.MAX_VALUE else (lengthS * rate).toLong()
        private val settleFrames = if (lengthS == Double.MAX_VALUE) 0L else (SETTLE_SECONDS * rate).toLong()
        private val subSize = rate / 10
        private val subBlocks = ArrayList<Double>()
        private var subAcc = 0.0
        private var subCount = 0
        private var frames = 0L

        val done get() = frames >= targetFrames

        fun add(energy: Double) {
            frames++
            if (frames <= settleFrames || frames > targetFrames) return
            subAcc += energy
            if (++subCount == subSize) {
                subBlocks.add(subAcc / subSize)
                subAcc = 0.0
                subCount = 0
            }
        }

        fun blocksTo(out: MutableList<Double>) {
            for (i in 0..subBlocks.size - 4) {
                out.add((subBlocks[i] + subBlocks[i + 1] + subBlocks[i + 2] + subBlocks[i + 3]) / 4)
            }
        }
    }

    /**
     * WAV (PCM 16/24/32 bits o float): se lee directamente, sin decodificador. El decodificador "audio/raw"
     * de Android se queda atascado con estos ficheros. Devuelve null si no es un WAV PCM.
     */
    private fun measureWav(path: String): Double? {
        RandomAccessFile(File(path), "r").use { raf ->
            val length = raf.length()
            val head = ByteArray(12)
            if (raf.read(head) != 12 || String(head, 0, 4) != "RIFF" || String(head, 8, 4) != "WAVE") return null
            var format = 0
            var channels = 0
            var rate = 0
            var bits = 0
            var offset = 12L
            val chunk = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            while (offset + 8 <= length) {
                raf.seek(offset)
                chunk.clear()
                raf.readFully(chunk.array())
                val id = String(chunk.array(), 0, 4)
                val size = chunk.getInt(4).toLong() and 0xffffffffL
                if (id == "fmt ") {
                    val fmt = ByteBuffer.allocate(minOf(size, 40L).toInt()).order(ByteOrder.LITTLE_ENDIAN)
                    raf.readFully(fmt.array())
                    format = fmt.getShort(0).toInt() and 0xffff
                    channels = fmt.getShort(2).toInt()
                    rate = fmt.getInt(4)
                    bits = fmt.getShort(14).toInt()
                    // WAVE_FORMAT_EXTENSIBLE: el formato real está en el subformato
                    if (format == 0xFFFE && size >= 26) format = fmt.getShort(24).toInt() and 0xffff
                } else if (id == "data") {
                    if (rate <= 0 || channels <= 0) return null
                    val encoding = when {
                        format == 3 && bits == 32 -> AudioFormat.ENCODING_PCM_FLOAT
                        format != 1 -> return null
                        bits == 16 -> AudioFormat.ENCODING_PCM_16BIT
                        bits == 24 -> AudioFormat.ENCODING_PCM_24BIT_PACKED
                        bits == 32 -> AudioFormat.ENCODING_PCM_32BIT
                        else -> return null
                    }
                    val frameBytes = channels * bits / 8
                    val dataStart = offset + 8
                    // Algunos WAV largos llevan un tamaño de datos incorrecto: se limita al fichero real
                    val dataSize = if (size == 0L || dataStart + size > length) length - dataStart else size
                    val durationS = dataSize.toDouble() / (frameBytes.toLong() * rate)

                    val blocks = ArrayList<Double>()
                    val buffer = ByteBuffer.allocate(frameBytes * 8192).order(ByteOrder.LITTLE_ENDIAN)
                    for ((start, lengthS) in windows(durationS)) {
                        val filter = KFilter(rate.toDouble(), channels, encoding)
                        val acc = WindowAccumulator(rate, lengthS)
                        var pos = dataStart + (start * rate).toLong() * frameBytes
                        val end = dataStart + dataSize
                        raf.seek(pos)
                        while (!acc.done && pos < end) {
                            val want = minOf(buffer.capacity().toLong(), end - pos).toInt() / frameBytes * frameBytes
                            if (want <= 0) break
                            raf.readFully(buffer.array(), 0, want)
                            pos += want
                            buffer.position(0)
                            buffer.limit(want)
                            filter.process(buffer) { acc.add(it) }
                        }
                        acc.blocksTo(blocks)
                    }
                    return integrated(blocks)
                }
                offset += 8 + size + (size and 1L)
            }
        }
        return null
    }

    /** MP3, AAC, M4A, FLAC…: se decodifica con MediaCodec. */
    private fun measureDecoded(path: String): Double? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L

            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            val blockEnergies = ArrayList<Double>()
            for ((start, length) in windows(durationUs / 1e6)) {
                extractor.seekTo((start * 1e6).toLong(), MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                codec.flush()
                decodeWindow(extractor, codec, length, blockEnergies)
            }
            return integrated(blockEnergies)
        } catch (e: Exception) {
            return null
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            extractor.release()
        }
    }

    /** Decodifica [lengthS] segundos desde la posición actual y añade la energía de sus bloques de 400 ms. */
    private fun decodeWindow(extractor: MediaExtractor, codec: MediaCodec, lengthS: Double, out: MutableList<Double>) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var filter: KFilter? = null
        var acc: WindowAccumulator? = null
        val deadline = System.currentTimeMillis() + WINDOW_DEADLINE_MS

        while (System.currentTimeMillis() < deadline) {
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val buffer = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || (outIndex >= 0 && filter == null)) {
                val f = codec.outputFormat
                val rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val encoding = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) f.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                filter = KFilter(rate.toDouble(), channels, encoding)
                if (acc == null) acc = WindowAccumulator(rate, lengthS)
            }
            if (outIndex >= 0) {
                val buffer = codec.getOutputBuffer(outIndex)!!
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                val a = acc!!
                filter!!.process(buffer.slice().order(ByteOrder.LITTLE_ENDIAN)) { a.add(it) }
                codec.releaseOutputBuffer(outIndex, false)
                if (a.done || (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            } else if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER && inputDone) {
                // Algunos decodificadores no marcan el final: se da por terminado tras vaciarse
                val again = codec.dequeueOutputBuffer(info, TIMEOUT_US * 10)
                if (again < 0) break
                codec.releaseOutputBuffer(again, false)
            }
        }
        acc?.blocksTo(out)
    }

    private fun loudness(energy: Double) = -0.691 + 10 * log10(energy)

    private fun integrated(blocks: List<Double>): Double? {
        val absolute = blocks.filter { it > 0 && loudness(it) > -70.0 }
        if (absolute.isEmpty()) return null
        val relativeGate = loudness(absolute.average()) - 10.0
        val gated = absolute.filter { loudness(it) > relativeGate }
        return loudness((if (gated.isEmpty()) absolute else gated).average())
    }

    /** Ponderación K (dos biquads por canal) para cualquier frecuencia de muestreo, como libebur128. */
    private class KFilter(rate: Double, private val channels: Int, private val encoding: Int) {
        private val b = DoubleArray(5)
        private val a = DoubleArray(5)
        private val state = Array(channels) { DoubleArray(5) }

        init {
            var f0 = 1681.974450955533
            val g = 3.999843853973347
            var q = 0.7071752369554196
            var k = tan(PI * f0 / rate)
            val vh = 10.0.pow(g / 20.0)
            val vb = vh.pow(0.4996667741545416)
            val pb = doubleArrayOf((vh + vb * k / q + k * k), 2 * (k * k - vh), (vh - vb * k / q + k * k))
            val a0 = 1 + k / q + k * k
            val pa = doubleArrayOf(1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
            for (i in 0..2) pb[i] /= a0

            f0 = 38.13547087602444
            q = 0.5003270373238773
            k = tan(PI * f0 / rate)
            val rb = doubleArrayOf(1.0, -2.0, 1.0)
            val ra = doubleArrayOf(1.0, 2 * (k * k - 1) / (1 + k / q + k * k), (1 - k / q + k * k) / (1 + k / q + k * k))

            // Ambas etapas combinadas en un filtro de orden 4 (convolución de coeficientes)
            for (i in 0..2) for (j in 0..2) {
                b[i + j] += pb[i] * rb[j]
                a[i + j] += pa[i] * ra[j]
            }
        }

        /** Llama a [onFrame] con la energía ponderada (suma de canales, peso 1) de cada fotograma. */
        inline fun process(buffer: ByteBuffer, onFrame: (Double) -> Unit) {
            val bytes = when (encoding) {
                AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
                AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
                else -> 2
            }
            val frameBytes = bytes * channels
            while (buffer.remaining() >= frameBytes) {
                var energy = 0.0
                for (c in 0 until channels) {
                    val x = when (encoding) {
                        AudioFormat.ENCODING_PCM_FLOAT -> buffer.float.toDouble()
                        AudioFormat.ENCODING_PCM_32BIT -> buffer.int / 2147483648.0
                        AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
                            val lo = buffer.get().toInt() and 0xff
                            val mid = buffer.get().toInt() and 0xff
                            val hi = buffer.get().toInt()
                            ((hi shl 16) or (mid shl 8) or lo) / 8388608.0
                        }
                        else -> buffer.short / 32768.0
                    }
                    val s = state[c]
                    // Forma directa II del filtro de orden 4
                    val w = x - a[1] * s[0] - a[2] * s[1] - a[3] * s[2] - a[4] * s[3]
                    val y = b[0] * w + b[1] * s[0] + b[2] * s[1] + b[3] * s[2] + b[4] * s[3]
                    s[3] = s[2]; s[2] = s[1]; s[1] = s[0]; s[0] = w
                    energy += y * y
                }
                onFrame(energy)
            }
        }
    }
}
