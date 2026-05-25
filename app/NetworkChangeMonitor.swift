import Foundation
import Network

/// Notifies on network-path changes (Wi-Fi ⇄ Ethernet ⇄ hotspot ⇄ down).
/// Used to re-apply system-proxy settings on the newly active service so
/// blocking survives the switch — networksetup only applies to services
/// that existed when we last enumerated them.
///
/// NWPathMonitor fires liberally (every minor IP change, captive portal
/// transitions, …); we debounce so we don't run `networksetup` ten times
/// in a row when the user roams between Wi-Fi networks.
final class NetworkChangeMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "focusshield.network-monitor")
    private var debounceWork: DispatchWorkItem?
    private let debounce: TimeInterval = 1.0

    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.debounceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.onChange?() }
                self.debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce, execute: work)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        debounceWork?.cancel()
        debounceWork = nil
    }
}
