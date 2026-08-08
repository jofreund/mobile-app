package io.music_assistant.client.api

import co.touchlab.kermit.Logger
import io.music_assistant.client.utils.myJson
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonPrimitive

data class Answer(
    val json: JsonObject,
) {
    val messageId: String? = json["message_id"]?.jsonPrimitive?.contentOrNull
    val result: JsonElement? = json["result"]

    /** The server answered with an `error_code` payload instead of a result. */
    val isError: Boolean = json.containsKey("error_code")

    /** The server's explanation for [isError], when it supplied one. */
    val errorDetails: String? = (json["details"] as? JsonPrimitive)?.contentOrNull

    /**
     * Decode the RPC result payload as [T], returning `null` if there's no
     * result or if the payload doesn't match the Kotlin model. Decode
     * failures are logged with a truncated JSON preview (so the reason is
     * recoverable from logs) rather than thrown — an uncaught
     * [SerializationException] on a background coroutine dispatcher aborts
     * the whole Kotlin/Native process, so schema drift must stay local to the
     * affected RPC rather than crash the app.
     */
    inline fun <reified T : Any> resultAs(): T? {
        val payload = result ?: return null
        return try {
            myJson.decodeFromJsonElement<T>(payload)
        } catch (e: SerializationException) {
            logger.w(e) {
                val preview = payload.toString().take(500)
                "Failed to decode RPC result as ${T::class.simpleName}: $preview"
            }
            null
        }
    }

    companion object {
        // `@PublishedApi internal` (not `private`) is required so the inline
        // `resultAs` above can reference this from call-site bytecode.
        @PublishedApi
        internal val logger = Logger.withTag("Answer")
    }
}

/**
 * The request reached the server *and* the server accepted it.
 *
 * [ServiceClient.sendRequest] resolves an answer carrying an `error_code` as
 * `Result.success` — `Result.failure` is reserved for transport-level problems (not connected,
 * cancelled, timed out), so a plain `isSuccess` check reads a rejection as a success. Anything
 * that reports an outcome back to the user, or writes optimistic local state off the back of
 * one, has to check this instead.
 */
val Result<Answer>.isAccepted: Boolean
    get() = getOrNull()?.isError == false
