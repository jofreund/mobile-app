package io.music_assistant.client.platform

/**
 * Opaque handle to whatever the platform needs to reach its own services — an `Application` on
 * Android, nothing at all on iOS. Consumed by the image loader, the log sharer and the network
 * monitor; none of them care what it contains.
 *
 * It used to be declared at the bottom of `MediaPlayerController.kt`, in the `player` package,
 * purely because that was the first thing to need one. Deleting the local player nearly took it
 * along, which is the argument for it living somewhere that describes what it is.
 */
expect class PlatformContext
