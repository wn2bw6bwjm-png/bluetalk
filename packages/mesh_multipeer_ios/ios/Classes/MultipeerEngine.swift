import Foundation
import MultipeerConnectivity
import Security

/// Raw packet pipe over Apple's Multipeer Connectivity.
///
/// Knows nothing about the mesh protocol; it reports events using the bridge
/// protocol documented in `mesh_core/lib/src/networking/native_transport.dart`.
///
/// Design notes
/// - Every device both advertises and browses.
/// - To avoid two simultaneous invitations (A→B and B→A) only the device whose
///   random per-session token is SMALLER invites; the other just accepts.
/// - The advertised `MCPeerID.displayName` is a random token, never the user's
///   name or peer ID, so nearby observers cannot track a person. Names are
///   exchanged only after connect, inside a signed announce.
/// - MCSession gives transport encryption (`.required`) but it is NOT relied on
///   for confidentiality: messages are end-to-end encrypted by mesh_core.
///
/// Platform limits (also in README):
/// - Multipeer works between Apple devices only (no Android interop).
/// - It stops when the app is suspended in the background; no background
///   delivery is possible with this transport.
/// - iOS shows the Local Network permission prompt on first use.
final class MultipeerEngine: NSObject {
    static let serviceType = "bluetalk" // 1–15 chars: a–z, 0–9, hyphen
    /// Multipeer sends large messages itself; one chunk per packet is enough.
    static let linkMtu = 32 * 1024

    private let emit: ([String: Any?]) -> Void
    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var token = ""
    private var connected: [String: MCPeerID] = [:]   // token -> peer
    private var announced = Set<String>()             // tokens already reported as discovered
    private var inviting = Set<String>()

    init(emit: @escaping ([String: Any?]) -> Void) {
        self.emit = emit
        super.init()
    }

    func start() {
        guard session == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 6)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            emit(["t": "error", "message": "Secure random generation failed"])
            return
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()

        let me = MCPeerID(displayName: token)
        peerID = me
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        let adv = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let br = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        peerID = nil
        for t in connected.keys { emit(["t": "down", "link": t]) }
        connected.removeAll()
        announced.removeAll()
        inviting.removeAll()
    }

    /// Returns nil on success or an error description.
    func send(link: String, data: Data) -> String? {
        guard let s = session, let peer = connected[link] else { return "Unknown or not ready link: \(link)" }
        if data.count > Self.linkMtu { return "Chunk of \(data.count) bytes exceeds \(Self.linkMtu)" }
        do {
            try s.send(data, toPeers: [peer], with: .reliable)
            return nil
        } catch {
            return "send failed: \(error.localizedDescription)"
        }
    }

    func disconnect(link: String) {
        // MCSession cannot drop a single peer; closing is all-or-nothing, so
        // this is intentionally a no-op. The link ends when the peer leaves.
    }
}

// MARK: - Session

extension MultipeerEngine: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            let t = peerID.displayName
            switch state {
            case .connected:
                self.inviting.remove(t)
                self.connected[t] = peerID
                self.emit(["t": "up", "link": t, "mtu": Self.linkMtu])
            case .notConnected:
                self.inviting.remove(t)
                if self.connected.removeValue(forKey: t) != nil {
                    self.emit(["t": "down", "link": t])
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            let t = peerID.displayName
            guard self.connected[t] != nil else { return }
            self.emit(["t": "chunk", "link": t, "data": data])
        }
    }

    // Unused: we only exchange discrete messages.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser

extension MultipeerEngine: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            // Accept only service-matching peers we are not already connected to.
            if let s = self.session, self.connected[peerID.displayName] == nil {
                invitationHandler(true, s)
            } else {
                invitationHandler(false, nil)
            }
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            self.emit(["t": "error", "message": "Advertising failed: \(error.localizedDescription)"])
        }
    }
}

// MARK: - Browser

extension MultipeerEngine: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            let t = peerID.displayName
            if t == self.token { return }
            if self.announced.insert(t).inserted {
                self.emit(["t": "discovered", "link": t])
            }
            // Smaller token invites; larger token waits for the invitation.
            guard self.token < t, self.connected[t] == nil, !self.inviting.contains(t),
                  let s = self.session else { return }
            self.inviting.insert(t)
            browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.announced.remove(peerID.displayName)
            self.inviting.remove(peerID.displayName)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.emit(["t": "error", "message": "Browsing failed: \(error.localizedDescription)"])
        }
    }
}
