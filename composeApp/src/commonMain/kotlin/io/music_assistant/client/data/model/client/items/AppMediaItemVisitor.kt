package io.music_assistant.client.data.model.client.items

/**
 * Exhaustive dispatch over [AppMediaItem]'s 10 concrete subtypes, for Swift.
 *
 * Kotlin/Native does not export sealed-class exhaustiveness to Swift `switch` —
 * a Swift `if let album = item as? Album` chain compiles even if a case is
 * missing. A Kotlin-declared protocol closes that gap for free: Swift conforms
 * to [AppMediaItemVisitor], and both the [accept] `when` below *and* the Swift
 * conformance fail to compile if a subtype is ever added and left unhandled.
 *
 * This exists instead of adopting SKIE's enum bridging (see the plan) because
 * it also covers the far more common case of branching on [PlayableItem] /
 * [MarkableItem] — those stay plain `as?` casts on the exported interfaces;
 * a generated Swift enum can't express "is this thing playable" any better
 * than the sealed class already does.
 */
interface AppMediaItemVisitor<R> {
    fun visitAlbum(item: Album): R
    fun visitArtist(item: Artist): R
    fun visitAudiobook(item: Audiobook): R
    fun visitGenre(item: Genre): R
    fun visitPlaylist(item: Playlist): R
    fun visitPodcast(item: Podcast): R
    fun visitPodcastEpisode(item: PodcastEpisode): R
    fun visitRadioStation(item: RadioStation): R
    fun visitRecommendationFolder(item: RecommendationFolder): R
    fun visitTrack(item: Track): R
}

/** See [AppMediaItemVisitor]. The `when` below is what makes the exhaustiveness real. */
fun <R> AppMediaItem.accept(visitor: AppMediaItemVisitor<R>): R = when (this) {
    is Album -> visitor.visitAlbum(this)
    is Artist -> visitor.visitArtist(this)
    is Audiobook -> visitor.visitAudiobook(this)
    is Genre -> visitor.visitGenre(this)
    is Playlist -> visitor.visitPlaylist(this)
    is Podcast -> visitor.visitPodcast(this)
    is PodcastEpisode -> visitor.visitPodcastEpisode(this)
    is RadioStation -> visitor.visitRadioStation(this)
    is RecommendationFolder -> visitor.visitRecommendationFolder(this)
    is Track -> visitor.visitTrack(this)
}
