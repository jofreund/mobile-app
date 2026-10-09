package io.music_assistant.client.data.announcement

import io.music_assistant.client.utils.myJson
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** The fork's send-on-release path over upstream's protocol: what reached the server, and when. */
@OptIn(ExperimentalCoroutinesApi::class)
class RecordedAnnouncementTest {
    private class FakeLink(private val failBinaryAfter: Int = Int.MAX_VALUE) : AnnouncementLink {
        val server = Channel<LinkInbound>(Channel.UNLIMITED)
        val sent = mutableListOf<Any>() // String for text, ByteArray for binary
        var closed = false

        override val inbound: Flow<LinkInbound> = server.consumeAsFlow()
        override suspend fun sendText(text: String) {
            sent += text
        }
        override suspend fun sendBinary(bytes: ByteArray) {
            check(sent.count { it is ByteArray } < failBinaryAfter) { "Link went away" }
            sent += bytes
        }
        override suspend fun close() {
            closed = true
        }

        fun reply(type: String) = server.trySend(LinkInbound.Text("""{"type":"$type"}"""))
        fun types() = sent.map { (it as? String)?.let { text -> text.type() } ?: "audio" }
    }

    private class Progress {
        var leftDevice = 0
    }

    private fun TestScope.send(link: FakeLink, pcm: ByteArray, progress: Progress = Progress()) = async {
        runRecordedAnnouncement(link, "token-1", "player-1", pcm, 24_000, AnnouncementOptions()) {
            progress.leftDevice++
        }
    }

    @Test
    fun `nothing leaves before started and the whole clip goes out at once after it`() = runTest {
        val link = FakeLink()
        val progress = Progress()
        val result = send(link, ByteArray(40_000) { it.toByte() }, progress)
        runCurrent()
        assertEquals(listOf("auth", "start"), link.types())
        assertEquals(0, progress.leftDevice)

        link.reply("started")
        runCurrent()
        assertEquals(listOf("auth", "start", "audio", "audio", "audio", "stop"), link.types())
        assertEquals(1, progress.leftDevice)

        link.reply("finished")
        assertEquals(ClipResult(played = true, reason = null, audioSent = true, stopSent = true), result.await())
        assertTrue(link.closed)
    }

    @Test
    fun `frames keep every byte in order and never split a sample`() {
        val pcm = ByteArray(40_000) { (it % 251).toByte() }
        val frames = pcm.frames()

        assertTrue(frames.all { it.size % 2 == 0 })
        assertEquals(pcm.toList(), frames.flatMap { it.toList() })
    }

    @Test
    fun `start carries the clip's rate`() = runTest {
        val link = FakeLink()
        val result = send(link, ByteArray(2))
        runCurrent()

        val start = myJson.parseToJsonElement(link.sent[1] as String).jsonObject
        assertEquals(24_000, start.getValue("sample_rate").jsonPrimitive.content.toInt())
        link.server.trySend(LinkInbound.Closed(null, null))
        result.await()
    }

    @Test
    fun `a rejection before started sent no audio and is safe to resend`() = runTest {
        val link = FakeLink()
        val progress = Progress()
        val result = send(link, ByteArray(2), progress)
        link.server.trySend(LinkInbound.Closed(4001, "Too many live announcements in progress"))

        assertEquals(
            ClipResult(
                played = false,
                reason = "Too many live announcements in progress",
                audioSent = false,
                stopSent = false,
            ),
            result.await(),
        )
        assertEquals(0, progress.leftDevice)
    }

    @Test
    fun `no started in time sent no audio`() = runTest {
        val link = FakeLink()
        val result = send(link, ByteArray(2))
        advanceTimeBy(16.seconds)

        assertEquals(ClipResult(played = false, reason = null, audioSent = false, stopSent = false), result.await())
    }

    @Test
    fun `a link lost mid-clip counts as audio sent but not stopped`() = runTest {
        val link = FakeLink(failBinaryAfter = 1)
        val progress = Progress()
        val result = send(link, ByteArray(40_000), progress)
        link.reply("started")

        val outcome = result.await()
        assertFalse(outcome.played)
        assertTrue(outcome.audioSent)
        assertFalse(outcome.stopSent)
        assertEquals(0, progress.leftDevice)
        assertTrue("stop" !in link.types())
    }

    @Test
    fun `a playback error after the stop keeps the server's words`() = runTest {
        val link = FakeLink()
        val result = send(link, ByteArray(2))
        link.reply("started")
        runCurrent()
        link.server.trySend(LinkInbound.Text("""{"type":"error","message":"Player is no longer available"}"""))

        assertEquals(
            ClipResult(played = false, reason = "Player is no longer available", audioSent = true, stopSent = true),
            result.await(),
        )
    }
}

private fun String.type() = myJson.parseToJsonElement(this).jsonObject["type"]?.jsonPrimitive?.content
