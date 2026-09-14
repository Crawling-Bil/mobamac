import Foundation

/// Something a terminal view can be wired up to. SSHConnectionSession is the
/// only conformer right now — the local-terminal tab is handled directly by
/// SwiftTerm's own LocalProcessTerminalView (see LocalTerminalHostView) since
/// it already owns the read/write loop for a local PTY and doesn't need this
/// abstraction.
protocol ConnectionSession: AnyObject {
    /// Called with every byte that arrives from the remote side.
    var onOutput: ((Data) -> Void)? { get set }
    /// Called once the connection ends, with an optional error.
    var onClose: ((Error?) -> Void)? { get set }

    func start() async throws
    func send(_ data: Data) async
    func resize(cols: Int, rows: Int) async
    func close() async
}
