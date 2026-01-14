import Foundation

#if canImport(Network)
import Network
#endif

/// Peer discovery using mDNS/Bonjour on local networks.
///
/// LocalNetworkDiscovery uses Apple's Network framework (NWBrowser and NWListener)
/// to discover and advertise peers on the local network using mDNS/DNS-SD.
///
/// ## Example Usage
///
/// ```swift
/// let discovery = LocalNetworkDiscovery(serviceType: "_myapp._tcp")
///
/// // Advertise
/// try await discovery.advertise(info: ServiceInfo(
///     name: "MyDevice",
///     port: 50051
/// ))
///
/// // Discover
/// for try await peer in discovery.discover(timeout: .seconds(5)) {
///     print("Found: \(peer.name)")
/// }
/// ```
public actor LocalNetworkDiscovery: PeerDiscovery {
    /// The service type to discover (e.g., "_myapp._tcp").
    private let serviceType: String

    /// The domain to search (defaults to "local.").
    private let domain: String

    #if canImport(Network)
    /// The browser for discovering services.
    private var browser: NWBrowser?

    /// The listener for advertising.
    private var listener: NWListener?
    #endif

    /// Currently discovered peers.
    private var discoveredPeers: [String: DiscoveredPeer] = [:]

    /// Event continuation for streaming events.
    private var eventContinuation: AsyncStream<DiscoveryEvent>.Continuation?

    /// Whether we are currently advertising.
    private var isAdvertising = false

    /// The advertised service info.
    private var advertisedInfo: ServiceInfo?

    /// Creates a new LocalNetworkDiscovery.
    ///
    /// - Parameters:
    ///   - serviceType: The Bonjour service type (e.g., "_myapp._tcp").
    ///   - domain: The domain to search (defaults to "local.").
    public init(serviceType: String, domain: String = "local.") {
        self.serviceType = serviceType
        self.domain = domain
    }

    // MARK: - PeerDiscovery

    public func discover(timeout: Duration) async -> AsyncThrowingStream<DiscoveredPeer, Error> {
        #if canImport(Network)
        return AsyncThrowingStream { continuation in
            let browsingTask = Task {
                await self.startBrowsing(continuation: continuation, timeout: timeout)
            }

            continuation.onTermination = { @Sendable _ in
                browsingTask.cancel()
                Task {
                    await self.stopBrowsing()
                }
            }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: DiscoveryError.notSupported)
        }
        #endif
    }

    public func advertise(info: ServiceInfo) async throws {
        #if canImport(Network)
        guard !isAdvertising else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let port = NWEndpoint.Port(integerLiteral: UInt16(info.port))
            let listener = try NWListener(using: parameters, on: port)

            // Create TXT record from metadata
            var txtRecord = NWTXTRecord()
            for (key, value) in info.metadata {
                txtRecord[key] = value
            }

            listener.service = NWListener.Service(
                name: info.name,
                type: serviceType,
                domain: domain,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { connection in
                // Accept connections but we don't need to handle them here
                // The actual transport layer handles connections
                connection.cancel()
            }

            listener.start(queue: .global())
            self.listener = listener
            self.advertisedInfo = info
            self.isAdvertising = true

            eventContinuation?.yield(.advertisingStarted)
        } catch {
            throw DiscoveryError.advertisingFailed(error.localizedDescription)
        }
        #else
        throw DiscoveryError.notSupported
        #endif
    }

    public func stopAdvertising() async throws {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        advertisedInfo = nil
        isAdvertising = false
        eventContinuation?.yield(.advertisingStopped)
        #endif
    }

    public var events: AsyncStream<DiscoveryEvent> {
        get async {
            AsyncStream { continuation in
                self.eventContinuation = continuation
            }
        }
    }

    // MARK: - Private

    #if canImport(Network)
    private func startBrowsing(
        continuation: AsyncThrowingStream<DiscoveredPeer, Error>.Continuation,
        timeout: Duration
    ) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: domain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleBrowserState(state, continuation: continuation)
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { [weak self] in
                await self?.handleBrowseResults(changes: changes, continuation: continuation)
            }
        }

        browser.start(queue: .global())
        self.browser = browser

        // Set timeout (cancellable via Task.isCancelled)
        Task {
            do {
                try await Task.sleep(for: timeout)
                if !Task.isCancelled {
                    await self.stopBrowsing()
                    continuation.finish()
                }
            } catch {
                // Task was cancelled, do nothing
            }
        }
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func handleBrowserState(
        _ state: NWBrowser.State,
        continuation: AsyncThrowingStream<DiscoveredPeer, Error>.Continuation
    ) {
        switch state {
        case .failed(let error):
            continuation.finish(throwing: DiscoveryError.discoveryFailed(error.localizedDescription))
            browser = nil
        case .cancelled:
            continuation.finish()
            browser = nil
        default:
            break
        }
    }

    private func handleBrowseResults(
        changes: Set<NWBrowser.Result.Change>,
        continuation: AsyncThrowingStream<DiscoveredPeer, Error>.Continuation
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                if let peer = createPeer(from: result) {
                    discoveredPeers[peer.peerID.value] = peer
                    eventContinuation?.yield(.peerAppeared(peer))
                    continuation.yield(peer)
                }
            case .removed(let result):
                if case .service(let name, _, _, _) = result.endpoint {
                    if let peer = discoveredPeers.removeValue(forKey: name) {
                        eventContinuation?.yield(.peerDisappeared(peer.peerID))
                    }
                }
            default:
                break
            }
        }
    }

    private func createPeer(from result: NWBrowser.Result) -> DiscoveredPeer? {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return nil
        }

        // Extract metadata from TXT record
        var metadata: [String: String] = [:]
        if case .bonjour(let txtRecord) = result.metadata {
            metadata = txtRecord.dictionary
        }

        // For now, we create the peer with the service name
        // The actual host/port will be resolved when connecting
        // We use a placeholder endpoint that will be resolved later
        return DiscoveredPeer(
            peerID: PeerID(name),
            name: name,
            endpoint: Endpoint(host: "\(name).local", port: 0),  // Will be resolved on connect
            metadata: metadata
        )
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            eventContinuation?.yield(.error(.advertisingFailed(error.localizedDescription)))
            isAdvertising = false
        case .cancelled:
            if isAdvertising {
                eventContinuation?.yield(.advertisingStopped)
                isAdvertising = false
            }
        case .ready:
            // Successfully started
            break
        default:
            break
        }
    }
    #endif
}
