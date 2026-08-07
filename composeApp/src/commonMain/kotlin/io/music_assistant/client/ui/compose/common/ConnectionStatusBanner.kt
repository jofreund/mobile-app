package io.music_assistant.client.ui.compose.common

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.ui.AppBannerState
import io.music_assistant.client.ui.AppRootRouter
import io.music_assistant.client.ui.Timings
import kotlinx.coroutines.delay
import musicassistantclient.composeapp.generated.resources.Res
import musicassistantclient.composeapp.generated.resources.banner_no_network
import musicassistantclient.composeapp.generated.resources.banner_reconnecting
import musicassistantclient.composeapp.generated.resources.common_cancel
import org.jetbrains.compose.resources.stringResource
import org.koin.compose.koinInject

/**
 * Global banner that shows reconnection status indicator.
 */
@Composable
fun ConnectionStatusBanner(
    modifier: Modifier = Modifier,
    delay: Long = Timings.UI_RETRY_DEBOUNCE,
) {
    val serviceClient: ServiceClient = koinInject()
    val router: AppRootRouter = koinInject()
    val bannerState by router.bannerState.collectAsStateWithLifecycle()

    // Delay visibility to not spam in cases reconnecting is fast. This stays a
    // local Compose concern (not part of AppRootRouter's bannerState) — it's
    // display timing, not the "is there a banner" decision itself.
    var isVisible by remember { mutableStateOf(false) }
    if (bannerState != null) {
        LaunchedEffect(Unit) {
            delay(delay)
            isVisible = true
        }
    } else {
        isVisible = false
    }

    AnimatedVisibility(
        visible = isVisible,
        enter = expandVertically(),
        exit = shrinkVertically(),
    ) {
        bannerState?.let { banner ->
            StatusBanner(
                text = when (banner) {
                    is AppBannerState.Reconnecting ->
                        stringResource(Res.string.banner_reconnecting, banner.attempt)

                    AppBannerState.NoNetwork -> stringResource(Res.string.banner_no_network)
                },
                onCancel = { serviceClient.disconnectByUser() },
                modifier = modifier,
            )
        }
    }
}

@Composable
private fun StatusBanner(
    text: String,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.secondaryContainer)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.padding(end = 8.dp).size(16.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
                Text(
                    text = text,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            androidx.compose.material3.TextButton(
                onClick = onCancel,
            ) {
                Text(
                    text = stringResource(Res.string.common_cancel),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
        }
    }
}
