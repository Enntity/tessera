import AppKit
import TesseraHost

extension AppModel {
    /// Another Tessera already runs this board: bring it forward and quit, rather than resume every
    /// agent a second time.
    func handOffToRunningCopy() -> Bool {
        guard let holder = workspace.boardHolder else { return false }
        FileHandle.standardError.write(Data("Tessera is already running with this board (pid \(holder)).\n".utf8))
        NSRunningApplication(processIdentifier: holder)?.activate()
        NSApp.terminate(nil)
        return true
    }

    /// Saved files Tessera couldn't fully read were kept aside rather than overwritten; say so once.
    func reportUnreadableFiles() {
        let copies = StateFile.keptAside
        guard !copies.isEmpty else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Some saved settings couldn't be read"
            alert.informativeText = "Tessera restored what it could and kept a copy of each file it couldn't read in full "
                + "(a newer Tessera may have written it):\n\n" + copies.map(\.lastPathComponent).joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(copies) }
        }
    }
}
