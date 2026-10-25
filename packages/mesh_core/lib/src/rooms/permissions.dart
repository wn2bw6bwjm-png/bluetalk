/// Roles inside a room. Wire values are stable.
enum Role {
  owner(3),
  admin(2),
  member(1);

  const Role(this.wire);
  final int wire;

  /// Higher rank can manage lower ranks.
  int get rank => wire;

  static Role? fromWire(int v) {
    for (final r in Role.values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

enum Permission {
  sendMessages,
  deleteMessages,
  manageMembers,
  manageChannels,
  manageRoom,
  manageRoles,
  deleteRoom,
}

/// Static permission matrix.
///
/// * owner  - everything, including promoting admins and deleting the room.
/// * admin  - room settings, channels, adding/removing members (not admins or
///            the owner), deleting any message.
/// * member - sending messages.
Set<Permission> permissionsOf(Role role) => switch (role) {
      Role.owner => Permission.values.toSet(),
      Role.admin => {
          Permission.sendMessages,
          Permission.deleteMessages,
          Permission.manageMembers,
          Permission.manageChannels,
          Permission.manageRoom,
        },
      Role.member => {Permission.sendMessages},
    };
