package io.music_assistant.client.auth

import io.music_assistant.client.api.APICommands
import io.music_assistant.client.api.Request
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PkceTest {
    @Test
    fun theChallengeMatchesTheRfc7636Example() = runTest {
        // RFC 7636, appendix B.
        assertEquals(
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            Pkce.challengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        )
    }

    @Test
    fun aVerifierIsFortyThreeUrlSafeCharactersAndFreshEachTime() = runTest {
        val first = Pkce.create()
        val second = Pkce.create()

        assertEquals(43, first.verifier.length)
        assertTrue(first.verifier.all { it.isLetterOrDigit() || it == '-' || it == '_' })
        assertNotEquals(first.verifier, second.verifier)
        assertEquals(Pkce.challengeOf(first.verifier), first.challenge)
    }

    @Test
    fun aChallengeAsksTheServerToReturnToTheApp() {
        val request = Request.Auth.authorizationUrl("ha", "musicassistant://auth/callback", codeChallenge = "abc")

        assertEquals(APICommands.AUTH_AUTHORIZATION_URL, request.command)
        assertEquals("abc", request.args?.get("code_challenge")?.jsonPrimitive?.content)
        assertEquals("S256", request.args?.get("code_challenge_method")?.jsonPrimitive?.content)
        assertEquals("app", request.args?.get("redirect_target")?.jsonPrimitive?.content)
    }

    @Test
    fun withoutAChallengeTheRequestStaysAsOnServer210() {
        val request = Request.Auth.authorizationUrl("ha", "musicassistant://auth/callback")

        assertNull(request.args?.get("code_challenge"))
        assertNull(request.args?.get("redirect_target"))
    }
}
