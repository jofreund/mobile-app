import SwiftUI

/// Native port of Compose's `GroupSettingsDialog` (deleted in the dead-code cutover; original
/// at commit `e2514156`) — group/ungroup players, per-member volume/mute, and group volume,
/// presented as a sheet from the expanded player's header.
///
/// Looks the player up from `store.players` by id on every render rather than holding a copy,
/// so server echoes (a member joining/leaving, volume moved from another client) update the
/// open sheet live.
///
/// Dispatch fidelity notes (mirrors the Compose original exactly):
/// - Add/remove always target the *parent* player's id (`GroupManage`); volume/mute rows target
///   the *member's own* id — see `KmpHelper`'s grouping section for why the string-id
///   `playerAction` overload matters here.
/// - The pivot row shows the player's RAW own volume (`ownVolume`), except for `PlayerType.GROUP`
///   players, whose "own" volume *is* the group volume.
/// - The local (Sendspin) player's playback-delay row was deliberately not ported — that whole
///   feature is product-hidden right now.
struct GroupSettingsView: View {

    var store: PlayerBarStore
    let playerId: String

    @Environment(\.dismiss) private var dismiss

    private var player: PlayerBarItemView? {
        store.players.first { $0.id == playerId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    content(player)
                } else {
                    // Player vanished (disconnected) while the sheet was up — nothing to manage.
                    ContentUnavailableView {
                        Label(String(localized: "players_group_settings"), systemImage: "hifispeaker.2")
                    }
                }
            }
            .navigationTitle(String(localized: "players_group_settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common_done")) { dismiss() }
                }
            }
        }
    }

    private func content(_ player: PlayerBarItemView) -> some View {
        List {
            if player.isGrouped {
                Section {
                    VolumeControlRow(
                        volume: player.groupVolume,
                        isMuted: player.groupVolumeMuted,
                        showMute: true,
                        enabled: player.groupVolume != nil,
                        onMuteToggle: { store.toggleGroupMute(id: player.id, isMutedNow: player.groupVolumeMuted) },
                        onVolumeSet: { store.setGroupVolume(id: player.id, level: $0) }
                    )
                } header: {
                    Text(String(format: String(localized: "players_group_volume"), player.name))
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if player.isGroup {
                        // A GROUP-type player's own volume IS the group volume.
                        if player.groupVolume != nil {
                            VolumeControlRow(
                                volume: player.groupVolume,
                                isMuted: player.groupVolumeMuted,
                                showMute: player.canMute,
                                enabled: player.volumeSliderAccessible,
                                onMuteToggle: { store.toggleGroupMute(id: player.id, isMutedNow: player.groupVolumeMuted) },
                                onVolumeSet: { store.setGroupVolume(id: player.id, level: $0) }
                            )
                        }
                    } else if player.ownVolume != nil {
                        VolumeControlRow(
                            volume: player.ownVolume,
                            isMuted: player.ownVolumeMuted,
                            showMute: player.canMute,
                            enabled: player.volumeSliderAccessible,
                            onMuteToggle: { store.toggleMemberMute(id: player.id, isMutedNow: player.ownVolumeMuted) },
                            onVolumeSet: { store.setMemberVolume(id: player.id, level: $0) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            if !player.groupMembers.isEmpty {
                Section {
                    ForEach(player.groupMembers) { member in
                        GroupMemberRow(member: member, parentId: player.id, store: store)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One bound member or groupable candidate: name + join/leave button + volume row.
private struct GroupMemberRow: View {

    let member: GroupMemberBarItemView
    let parentId: String
    let store: PlayerBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(member.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .opacity(member.isBound ? 1 : 0.4)
                Spacer(minLength: 8)
                Button {
                    if member.isBound {
                        store.removeGroupMember(parentId: parentId, childId: member.id)
                    } else {
                        store.addGroupMember(parentId: parentId, childId: member.id)
                    }
                } label: {
                    Image(systemName: member.isBound ? "minus.circle" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(member.isBound ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.borderless)
                .disabled(!member.isManageable)
                .opacity(member.isManageable ? 1 : 0.4)
                .accessibilityLabel(
                    String(localized: member.isBound ? "cd_remove_from_group" : "cd_add_to_group")
                )
            }
            VolumeControlRow(
                volume: member.volume,
                isMuted: member.isMuted,
                showMute: member.canMute,
                enabled: member.isBound && member.volumeSliderAccessible && member.volume != nil,
                onMuteToggle: { store.toggleMemberMute(id: member.id, isMutedNow: member.isMuted) },
                onVolumeSet: { store.setMemberVolume(id: member.id, level: $0) }
            )
        }
        .padding(.vertical, 4)
    }
}

/// Mute icon + slider + numeric value — the same optimistic-drag pattern as the expanded
/// player's own volume row (local state while dragging, commit on release, server echo wins
/// afterwards). `@State` is keyed per row identity by the enclosing `ForEach`.
private struct VolumeControlRow: View {

    let volume: Float?
    let isMuted: Bool
    let showMute: Bool
    let enabled: Bool
    let onMuteToggle: () -> Void
    let onVolumeSet: (Float) -> Void

    @State private var dragValue: Float?

    private var displayValue: Float { dragValue ?? volume ?? 0 }

    var body: some View {
        HStack(spacing: 12) {
            if showMute {
                Button(action: onMuteToggle) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!enabled)
                .accessibilityLabel(String(localized: isMuted ? "cd_unmute" : "cd_mute"))
            }
            Slider(
                value: Binding(
                    get: { displayValue },
                    set: { dragValue = $0 }
                ),
                // Same 0...100 scale as every other volume surface (no /100 fractions anywhere).
                in: 0...100,
                onEditingChanged: { editing in
                    guard !editing, let level = dragValue else { return }
                    onVolumeSet(level)
                    dragValue = nil
                }
            )
            .disabled(!enabled)

            Text("\(Int(displayValue))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.4)
    }
}
