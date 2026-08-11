import SwiftUI

/// Native port of Compose's `GroupSettingsDialog` (deleted in the dead-code cutover; original
/// at commit `e2514156`) — group/ungroup players, per-member volume/mute, and group volume.
///
/// Content only: no navigation stack, no title, no Done button. It is swapped into
/// `PlayerPickerSheet` in place of the player list rather than presented over it, so the chrome
/// belongs to that sheet and this supplies the list alone.
///
/// Takes the player **value**, re-supplied by `ExpandedPlayerRow`'s own body on every store
/// update, rather than looking it up from `store.players` by id. That lookup version didn't
/// repaint on a join/leave: this view's only stored inputs would be the store reference and an
/// id string, neither of which ever changes, so SwiftUI had nothing to diff and kept the
/// already-rendered body. Passing the value is how every other live surface here works
/// (`MiniPlayerRow`, `ExpandedPlayerRow` — both fed from `ForEach(store.players)`), and it's
/// why `PlayerBarItemView` must not carry an id-only `Equatable` (see `PlayerBarStore.swift`).
/// The store stays for dispatching actions only.
///
/// Dispatch fidelity notes (mirrors the Compose original exactly):
/// - Add/remove always target the *parent* player's id (`GroupManage`); volume/mute rows target
///   the *member's own* id — see `KmpHelper`'s grouping section for why the string-id
///   `playerAction` overload matters here.
/// - The pivot row shows the player's RAW own volume (`ownVolume`), except for `PlayerType.GROUP`
///   players, whose "own" volume *is* the group volume.
/// - The local (Sendspin) player's playback-delay row was deliberately not ported — that whole
///   feature is product-hidden right now.
struct GroupSettingsContent: View {

    let player: PlayerBarItemView
    var store: PlayerBarStore

    var body: some View {
        List {
            if player.isGrouped {
                Section {
                    VolumeSlider(
                        volume: player.groupVolume,
                        isMuted: player.groupVolumeMuted,
                        canMute: true,
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
                            VolumeSlider(
                                volume: player.groupVolume,
                                isMuted: player.groupVolumeMuted,
                                canMute: player.canMute,
                                enabled: player.volumeSliderAccessible,
                                onMuteToggle: { store.toggleGroupMute(id: player.id, isMutedNow: player.groupVolumeMuted) },
                                onVolumeSet: { store.setGroupVolume(id: player.id, level: $0) }
                            )
                        }
                    } else if player.ownVolume != nil {
                        VolumeSlider(
                            volume: player.ownVolume,
                            isMuted: player.ownVolumeMuted,
                            canMute: player.canMute,
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
            VolumeSlider(
                volume: member.volume,
                isMuted: member.isMuted,
                canMute: member.canMute,
                enabled: member.isBound && member.volumeSliderAccessible && member.volume != nil,
                onMuteToggle: { store.toggleMemberMute(id: member.id, isMutedNow: member.isMuted) },
                onVolumeSet: { store.setMemberVolume(id: member.id, level: $0) }
            )
        }
        .padding(.vertical, 4)
    }
}
