// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import MultipeerConnectivity
import os
#if os(iOS)
import UIKit
#endif

/// Peer-to-peer transaction sync over the local network (Wi-Fi), using MultipeerConnectivity.
/// This is the free-account alternative to CloudKit: the user's own iPhone and Mac discover each
/// other on the same network and exchange their transaction ledgers directly — nothing leaves the
/// local network, no server, no paid capabilities (just the Local Network permission).
///
/// Each device both advertises and browses. On connecting, both sides send their full transaction
/// list; the receiver routes it through the store's existing merge/dedup (`applyRemote`), so the
/// two ledgers converge. Additive + field-merge only — deletions are not propagated in this mode.
///
/// The current ledger is kept as a lock-protected encoded snapshot (`updateLedger`) so the
/// MultipeerConnectivity delegate callbacks — which run on a background queue — never touch the
/// `@MainActor` store directly.
final class LocalSyncService: NSObject {

    /// ≤ 15 chars, lowercase/digits/hyphen — Bonjour service-type rules.
    private static let serviceType = "spendwise-sync"

    private let log = Logger(subsystem: "com.eduquizacademy.spendwise", category: "LocalSync")
    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let lock = NSLock()
    private var ledgerSnapshot: Data?   // most recent encoded [Transaction]

    /// Called (on the main actor) with transactions received from a peer.
    var onReceive: (([Transaction]) -> Void)?
    /// Called (on the main actor) when a peer connects — passes its display name, for UI status.
    var onConnected: ((String) -> Void)?

    override init() {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
        // MCPeerID display name is capped at 63 bytes.
        myPeerID = MCPeerID(displayName: String(name.prefix(63)))
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        log.info("Local sync started as \(self.myPeerID.displayName, privacy: .public)")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// Re-kicks discovery — call when the app launches or returns to the foreground, since iOS
    /// suspends MultipeerConnectivity in the background and the session needs re-establishing.
    func restart() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        log.info("Local sync restarted")
    }

    /// Updates the snapshot AND pushes it to any connected peers. Call from the store after the
    /// ledger changes (and once at startup).
    func updateLedger(_ transactions: [Transaction]) {
        let data = try? JSONEncoder().encode(transactions)
        lock.lock(); ledgerSnapshot = data; lock.unlock()
        guard let data, !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// Refreshes the snapshot WITHOUT sending — used after applying a peer's data, so a future
    /// peer connection gets the merged state without echoing changes back (which could oscillate).
    func refreshSnapshot(_ transactions: [Transaction]) {
        let data = try? JSONEncoder().encode(transactions)
        lock.lock(); ledgerSnapshot = data; lock.unlock()
    }

    private func sendLedger(to peers: [MCPeerID]) {
        lock.lock(); let data = ledgerSnapshot; lock.unlock()
        guard let data else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }
}

// MARK: - Advertiser: accept invitations

extension LocalSyncService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log.error("advertise failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Browser: invite discovered peers

extension LocalSyncService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        // Tie-break so the two devices don't invite each other simultaneously: only the
        // lexicographically-smaller name initiates. The other accepts via the advertiser.
        guard myPeerID.displayName < peerID.displayName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log.error("browse failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Session: exchange ledgers

extension LocalSyncService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            log.info("connected to \(peerID.displayName, privacy: .public) — sending ledger")
            sendLedger(to: [peerID])
            let name = peerID.displayName
            Task { @MainActor in self.onConnected?(name) }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let txs = try? JSONDecoder().decode([Transaction].self, from: data) else { return }
        Task { @MainActor in self.onReceive?(txs) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
