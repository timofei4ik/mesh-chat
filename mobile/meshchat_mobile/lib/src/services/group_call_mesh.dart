/// Small-group WebRTC topology. Ready means the user accepted the call,
/// not merely that their device received an invitation.
class GroupCallMesh {
  GroupCallMesh({
    required this.localNode,
    required this.hostNode,
    required Iterable<String> members,
  }) : invited = {...members, hostNode, localNode}..remove('');

  static const maxParticipants = 8;
  final String localNode;
  final String hostNode;
  final Set<String> invited;
  final Set<String> ready = {};
  final Set<String> departed = {};
  bool accepted = false;

  bool markReady(String node) {
    if (!invited.contains(node) ||
        node == localNode ||
        departed.contains(node)) {
      return false;
    }
    return ready.add(node);
  }

  void leave(String node) {
    ready.remove(node);
    departed.add(node);
  }

  bool shouldOffer(String node) =>
      accepted &&
      ready.contains(node) &&
      localNode != hostNode &&
      node != hostNode &&
      localNode.compareTo(node) < 0;

  bool acceptsOffer(String node) =>
      accepted &&
      ready.contains(node) &&
      localNode != hostNode &&
      node != hostNode &&
      node.compareTo(localNode) < 0;

  bool shouldRestart(String node) =>
      localNode == hostNode ||
      (node != hostNode && localNode.compareTo(node) < 0);
}
