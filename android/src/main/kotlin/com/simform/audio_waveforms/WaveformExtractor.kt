package com.simform.audio_waveforms

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.pow
import kotlin.math.sqrt
import androidx.core.net.toUri
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.MediaExtractorCompat

/**
 * WaveformExtractor handles the process of extracting amplitude data from audio files
 * to generate waveform visualizations.
 * 
 * This class uses the Android MediaCodec API to decode audio files and extract
 * RMS (Root Mean Square) values at regular intervals, which represent the amplitude
 * of the audio signal. These values can then be used to draw waveform visualizations.
 * 
 * The extractor supports various audio formats and bit depths (8-bit, 16-bit, and 32-bit)
 * and handles both mono and stereo audio channels.
 */
@OptIn(UnstableApi::class)
class WaveformExtractor(
    /** Path to the audio file to analyze */
    private val path: String,
    /** Number of waveform data points to generate */
    private val expectedPoints: Int,
    /** Unique identifier for this extraction process */
    private val key: String,
    /** Method channel for sending progress updates to Flutter */
    private val methodChannel: MethodChannel,
    /** Result callback for sending the final result back to Flutter */
    private val result: MethodChannel.Result,
    /** Callback for notifying about progress changes */
    private val extractorCallBack: ExtractorCallBack,
    /** Application context for accessing content URIs */
    private val context: Context,
) {
    /** MediaCodec for decoding audio data */
    private var decoder: MediaCodec? = null
    /** Media3, not the platform MediaExtractor: its Opus header for browser-recorded MP4 is rejected by the Opus decoder */
    private var extractor: MediaExtractorCompat? = null
    /** Format of the selected audio track, reported with errors */
    private var inputFormat: MediaFormat? = null
    /** Latch for synchronizing completion of the extraction process */
    private val finishCount = CountDownLatch(1)
    /** Flag indicating end of input data */
    private var inputEof = false
    /** Media3's FLAC extractor keeps returning the last sample at the end instead of -1, so a repeated time ends the input */
    private var lastQueuedSampleTimeUs = -1L
    /** Sample rate of the audio in Hz */
    private var sampleRate = 0
    /** Number of audio channels (1=mono, 2=stereo) */
    private var channels = 1
    /** AudioFormat encoding of the decoded PCM */
    private var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
    /** Flag to prevent submitting multiple results */
    private var isReplySubmitted = false
    /** Flag to ensure stop is only executed once */
    private val isStopped = AtomicBoolean(false)

    /** Whether [stop] has already released the decoder and the extractor. */
    val hasStopped: Boolean get() = isStopped.get()

    /**
     * Guards every use of [decoder] / [extractor] against a concurrent release.
     *
     * MediaCodec callbacks are dispatched on the looper of the thread that created the codec,
     * while a release can come from another thread entirely (the platform reclaiming the codec
     * under resource pressure, a finalizer, or a stop() from the plugin). Without this lock the
     * `isStopped` check is a check-then-use: the codec can be released between the check and
     * `getInputBuffer`/`readSampleData`, which is fatal (IllegalStateException, or a SIGSEGV
     * inside NuMediaExtractor::readSampleData writing into the freed input buffer).
     */
    private val lock = Any()

    /**
     * Retrieves the audio format from the given media file
     *
     * This method:
     * 1. Creates a MediaExtractor to read the file
     * 2. Finds the first audio track in the file
     * 3. Retrieves and selects that track
     *
     * @param path Path to the audio file (content URI format)
     * @return MediaFormat of the audio track, or null if no audio track is found
     */
    private fun getFormat(path: String): MediaFormat? {
        if (path.isEmpty()) {
            return null
        }
        val mediaExtractor = MediaExtractorCompat(context)
        this.extractor = mediaExtractor
        val uri = path.toUri()
        mediaExtractor.setDataSource(context, uri, null)
        val trackCount = mediaExtractor.trackCount
        repeat(trackCount) {
            val format = mediaExtractor.getTrackFormat(it)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.contains("audio")) {
                inputFormat = format
                mediaExtractor.selectTrack(it)
                return format
            }
        }
        return null
    }

    /**
     * Starts the decoding and waveform extraction process
     * 
     * This method initializes the MediaCodec decoder with appropriate
     * callbacks to process audio frames. It handles:
     * 1. Setting up the decoder with the proper format
     * 2. Processing input buffers from the MediaExtractor
     * 3. Processing decoded PCM audio data in output buffers
     * 4. Calculating RMS values for waveform visualization
     * 5. Reporting progress via the callback interface and method channel
     */
    fun startDecode() {
        try {
            val format = getFormat(path) ?: error("No audio format found")
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("No MIME type found")
            decoder = MediaCodec.createDecoderByType(mime).also {
                it.configure(format, null, null, 0)
                it.setCallback(object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                      synchronized(lock) {
                        if (isStopped.get() || inputEof || index < 0) return
                        val extractor = extractor ?: return
                        try {
                            codec.getInputBuffer(index)?.let { buf ->
                                val size = extractor.readSampleData(buf, 0)
                                val sampleTime = extractor.sampleTime
                                if (size > 0 && sampleTime > lastQueuedSampleTimeUs) {
                                    codec.queueInputBuffer(index, 0, size, sampleTime, 0)
                                    lastQueuedSampleTimeUs = sampleTime
                                    extractor.advance()
                                } else {
                                    codec.queueInputBuffer(
                                        index,
                                        0,
                                        0,
                                        0,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                    inputEof = true
                                }
                            }
                        } catch (e: IllegalStateException) {
                            // The codec was released or reclaimed underneath us.
                            inputEof = true
                            Log.w(Constants.LOG_TAG, "Input buffer unavailable: ${e.message}")
                        } catch (e: Exception) {
                            inputEof = true
                            if (!isReplySubmitted) {
                                isReplySubmitted = true
                                result.error(Constants.LOG_TAG, e.message, "Invalid input buffer: ${errorDetails(e)}")
                            }
                        }
                      }
                    }

                    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                      synchronized(lock) {
                        sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        pcmEncoding = if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                            format.containsKey(MediaFormat.KEY_PCM_ENCODING)
                        ) {
                            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        windowFrames = (sampleRate / WINDOWS_PER_SECOND).coerceAtLeast(1)
                      }
                    }

                    override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                        if (!isReplySubmitted) {
                            result.error(
                                Constants.LOG_TAG,
                                e.message,
                                "An error is thrown while decoding the audio file: codec=${runCatching { codec.name }.getOrNull()}, " +
                                    "errorCode=${e.errorCode}, diagnosticInfo=${e.diagnosticInfo}, ${errorDetails(e)}"
                            )
                            isReplySubmitted = true
                        }
                        stop()
                    }

                    override fun onOutputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                        info: MediaCodec.BufferInfo
                    ) {
                      synchronized(lock) {
                        if (isStopped.get() || index < 0 || decoder == null) return
                        
                        try {
                            if (info.size > 0) {
                                codec.getOutputBuffer(index)?.let { buf ->
                                    try {
                                        val size = info.size
                                        // Set both position and limit to ensure buffer is accessible
                                        buf.position(info.offset)
                                        buf.limit(info.offset + info.size)
                                        
                                        when (pcmEncoding) {
                                            AudioFormat.ENCODING_PCM_8BIT -> handle8bit(size, buf)
                                            AudioFormat.ENCODING_PCM_FLOAT -> handleFloat(size, buf)
                                            ENCODING_PCM_24BIT_PACKED -> handle24bit(size, buf)
                                            ENCODING_PCM_32BIT -> handle32bitInt(size, buf)
                                            else -> handle16bit(size, buf)
                                        }
                                    } catch (e: Exception) {
                                        Log.e(Constants.LOG_TAG, "Error processing output buffer: ${e.message}")
                                    }
                                }
                            }
                        } finally {
                            // Always release the buffer, even if processing failed
                            try {
                                codec.releaseOutputBuffer(index, false)
                            } catch (e: IllegalStateException) {
                                Log.e(Constants.LOG_TAG, "Error releasing output buffer: ${e.message}")
                            }
                        }

                        if (info.isEof()) {
                            finish()
                            stop()
                        }
                      }
                    }

                })
                it.start()
            }

        } catch (e: Exception) {
            if (!isReplySubmitted) {
                result.error(
                    Constants.LOG_TAG,
                    e.message,
                    "An error is thrown before decoding the audio file: ${errorDetails(e)}"
                )
                isReplySubmitted = true
            }
        }


    }

    private fun errorDetails(e: Exception) = "exception=${e.javaClass.name}, ${errorDetails()}"

    private fun errorDetails() = "file=${path.substringAfterLast('/')}, format=$inputFormat"

    /** Collected waveform amplitude data points */
    var sampleData = ArrayList<Float>()

    /**
     * The decoded audio is summed into short fixed windows and only split into [expectedPoints]
     * bars at the end of the stream, because the container duration can be missing or wrong
     * (browser-recorded fragmented MP4).
     */
    private var windowFrames = 1
    /** Sum of squared sample values per completed window */
    private var windowSums = DoubleArray(INITIAL_WINDOW_CAPACITY)
    private var windowCount = 0
    private var currentWindowFrames = 0
    private var currentWindowSum = 0.0

    /**
     * Accumulates one normalized sample (-1.0 to 1.0) into the current window
     */
    private fun handleBufferDivision(value: Float) {
        currentWindowSum += value.toDouble().pow(2.0)
        currentWindowFrames++
        if (currentWindowFrames == windowFrames) {
            appendWindow(currentWindowSum)
            currentWindowFrames = 0
            currentWindowSum = 0.0
        }
    }

    private fun appendWindow(sum: Double) {
        if (windowCount == windowSums.size) {
            windowSums = windowSums.copyOf(windowSums.size * 2)
        }
        windowSums[windowCount++] = sum
    }

    /**
     * Processes 8-bit PCM audio data
     *
     * Reads 8-bit samples from the buffer, normalizes them to the range [-1.0, 1.0],
     * and passes them to handleBufferDivision for RMS calculation.
     * 
     * @param size Size of the buffer in bytes
     * @param buf ByteBuffer containing the audio data
     */
    private fun handle8bit(size: Int, buf: ByteBuffer) {
        repeat(size / if (channels == 2) 2 else 1) {
            // ENCODING_PCM_8BIT is unsigned, with 128 as silence, while a Kotlin
            // Byte is signed: it has to be widened and then centered on zero.
            val sample = (buf.get().toInt() and 0xFF) - 128
            val result = sample / Constants.EIGHT_BITS
            if (channels == 2) {
                buf.get()
            }
            handleBufferDivision(result)
        }
    }

    /**
     * Processes 16-bit PCM audio data
     *
     * Reads 16-bit samples from the buffer, normalizes them to the range [-1.0, 1.0],
     * and passes them to handleBufferDivision for RMS calculation.
     * 
     * @param size Size of the buffer in bytes
     * @param buf ByteBuffer containing the audio data
     */
    private fun handle16bit(size: Int, buf: ByteBuffer) {
        repeat(size / if (channels == 2) 4 else 2) {
            // Little endian, low byte first. The low byte has to be masked: a
            // Kotlin Byte above 0x7F widens to a negative Int, and its sign bits
            // then swallow the high byte through the `or`. The high byte is left
            // signed on purpose — that is the sample's own sign.
            val low = buf.get().toInt() and 0xFF
            val high = buf.get().toInt() shl 8
            val value = (low or high) / Constants.SIXTEEN_BITS
            if (channels == 2) {
                buf.get()
                buf.get()
            }
            handleBufferDivision(value)
        }
    }

    /**
     * Processes 24-bit packed little-endian PCM, which Media3 passes through for 24-bit WAV and FLAC
     */
    private fun handle24bit(size: Int, buf: ByteBuffer) {
        repeat(size / if (channels == 2) 6 else 3) {
            val low = buf.get().toInt() and 0xFF
            val mid = buf.get().toInt() and 0xFF
            val high = buf.get().toInt() shl 16
            val value = (low or (mid shl 8) or high) / TWENTY_FOUR_BITS
            if (channels == 2) {
                buf.get()
                buf.get()
                buf.get()
            }
            handleBufferDivision(value)
        }
    }

    /**
     * Processes 32-bit signed integer little-endian PCM
     */
    private fun handle32bitInt(size: Int, buf: ByteBuffer) {
        val ints = buf.order(ByteOrder.LITTLE_ENDIAN).asIntBuffer()
        repeat(size / if (channels == 2) 8 else 4) {
            val value = ints.get() / Int.MAX_VALUE.toFloat()
            if (channels == 2) {
                ints.get()
            }
            handleBufferDivision(value)
        }
    }

    /**
     * Processes 32-bit float PCM audio data
     *
     * The samples are IEEE-754 floats already in the range [-1.0, 1.0] and are
     * read as such, then passed to handleBufferDivision for RMS calculation.
     *
     * @param size Size of the buffer in bytes
     * @param buf ByteBuffer containing the audio data
     */
    private fun handleFloat(size: Int, buf: ByteBuffer) {
        val floats = buf.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        repeat(size / if (channels == 2) 8 else 4) {
            val value = floats.get()
            if (channels == 2) {
                floats.get()
            }
            handleBufferDivision(value)
        }
    }

    /**
     * Splits the decoded windows into [expectedPoints] RMS bars and replies to Flutter once
     */
    private fun finish() {
        if (isReplySubmitted) return
        isReplySubmitted = true

        val lastWindowFrames = if (currentWindowFrames > 0) currentWindowFrames else windowFrames
        if (currentWindowFrames > 0) appendWindow(currentWindowSum)
        if (windowCount == 0 || expectedPoints <= 0) {
            result.error(Constants.LOG_TAG, "No audio decoded", "The audio file has no samples: ${errorDetails()}")
            return
        }

        repeat(expectedPoints) { point ->
            val start = (point.toLong() * windowCount / expectedPoints).toInt()
            val end = maxOf(start + 1, ((point + 1L) * windowCount / expectedPoints).toInt())
            var sum = 0.0
            var frames = 0L
            for (window in start until end) {
                sum += windowSums[window]
                frames += if (window == windowCount - 1) lastWindowFrames else windowFrames
            }
            sampleData.add(sqrt(sum / frames).toFloat())
        }

        val progress = 1F
        extractorCallBack.onProgress(progress)

        val args: MutableMap<String, Any?> = HashMap()
        args[Constants.waveformData] = sampleData
        args[Constants.progress] = progress
        args[Constants.playerKey] = key
        methodChannel.invokeMethod(
            Constants.onCurrentExtractedWaveformData,
            args
        )
    }

    /**
     * Stops the extraction process and releases resources
     *
     * This method:
     * 1. Stops and releases the MediaCodec decoder
     * 2. Releases the MediaExtractor
     * 3. Signals completion via the countdown latch
     *
     * Thread-safe: Uses atomic flag to ensure stop is only executed once,
     * preventing "codec is released already" exceptions.
     */
    fun stop() {
        synchronized(lock) {
            if (!isStopped.compareAndSet(false, true)) {
                return
            }

            val localDecoder = decoder
            val localExtractor = extractor
            decoder = null
            extractor = null

            try {
                localDecoder?.stop()
            } catch (e: IllegalStateException) {
                Log.w(Constants.LOG_TAG, "Decoder already stopped: ${e.message}")
            }

            try {
                localDecoder?.release()
            } catch (e: IllegalStateException) {
                Log.w(Constants.LOG_TAG, "Decoder already released: ${e.message}")
            }

            try {
                localExtractor?.release()
            } catch (e: IllegalStateException) {
                Log.w(Constants.LOG_TAG, "Extractor already released: ${e.message}")
            }
        }

        finishCount.countDown()
    }

    private companion object {
        const val WINDOWS_PER_SECOND = 100
        const val INITIAL_WINDOW_CAPACITY = 1024
        const val TWENTY_FOUR_BITS = 8388607f
        /** AudioFormat.ENCODING_PCM_24BIT_PACKED and ENCODING_PCM_32BIT are only public from API 31 */
        const val ENCODING_PCM_24BIT_PACKED = 21
        const val ENCODING_PCM_32BIT = 22
    }
}

/**
 * Extension function to check if a buffer contains the end-of-stream flag
 * 
 * @return true if this buffer marks the end of the stream, false otherwise
 */
fun MediaCodec.BufferInfo.isEof() = flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0

/**
 * Callback interface for reporting waveform extraction progress
 * 
 * Implementations of this interface receive progress updates during
 * the waveform extraction process.
 */
interface ExtractorCallBack {
    /**
     * Called when extraction progress changes
     * 
     * @param value Progress value from 0.0 to 1.0, where 1.0 indicates completion
     */
    fun onProgress(value: Float)
}