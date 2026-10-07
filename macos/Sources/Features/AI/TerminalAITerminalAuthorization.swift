import Darwin
import Foundation

/// Kernel process facts supplement reported OSC host and prompt metadata. They
/// establish only a direct local shell, never the identity of an SSH peer or
/// the safety of aliases, functions, shell hooks, or a proposed command.
enum TerminalAITerminalAuthorization {
    struct ProcessFacts: Codable, Equatable {
        let pid: Int32
        let parentPID: Int32
        let uid: UInt32
        let realUID: UInt32
        let savedUID: UInt32
        let processGroup: Int32
        let foregroundGroup: Int32
        let ttyDevice: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let path: String
    }

    struct ParentFacts: Codable, Equatable {
        let pid: Int32
        let parentPID: Int32
        let uid: UInt32
        let ttyDevice: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let path: String
    }

    /// Compare the complete snapshot again immediately before dispatch. PID
    /// alone would not distinguish a reused PID or a changed shell context.
    struct Identity: Codable, Equatable {
        let surfaceID: UUID
        let process: ProcessFacts
        let parent: ParentFacts?
    }

    @MainActor
    static func snapshot(view: Ghostty.SurfaceView) -> Identity? {
        guard view.surface != nil, !view.processExited, getuid() == geteuid(),
              let process = context(view: view) else { return nil }
        let parent = process.parentPID == getpid() ? nil : readParent(pid: process.parentPID)
        guard view.surfaceModel?.foregroundPID == Int(process.pid), !view.processExited else { return nil }
        return validate(process: process, parent: parent, surfaceID: view.id, appPID: getpid(), userID: getuid())
    }

    /// Explicit approval may target root, SSH, or a nested shell. Preserve their
    /// observed process facts too, so approval cannot silently change targets.
    @MainActor
    static func context(view: Ghostty.SurfaceView) -> ProcessFacts? {
        guard view.surface != nil, !view.processExited,
              let rawPID = view.surfaceModel?.foregroundPID, let pid = Int32(exactly: rawPID), pid > 0,
              let process = readProcess(pid: pid), view.surfaceModel?.foregroundPID == rawPID,
              !view.processExited else { return nil }
        return process
    }

    static func validate(process: ProcessFacts, parent: ParentFacts?, surfaceID: UUID,
                         appPID: Int32, userID: UInt32) -> Identity? {
        guard appPID > 0, userID != 0, process.pid > 0,
              process.uid == userID, process.realUID == userID, process.savedUID == userID,
              ["/bin/zsh", "/bin/bash"].contains(process.path),
              process.pid == process.processGroup, process.pid == process.foregroundGroup,
              process.ttyDevice != UInt32.max, process.startSeconds > 0,
              process.startMicroseconds < 1_000_000 else { return nil }
        if process.parentPID == appPID {
            guard parent == nil else { return nil }
        } else {
            // macOS login remains the parent of the interactive shell. No
            // deeper ancestry traversal: nested su, sudo, shells and SSH fail
            // closed even if they claim a local host and an empty OSC prompt.
            guard let parent, parent.pid == process.parentPID, parent.parentPID == appPID,
                  parent.path == "/usr/bin/login", parent.uid == 0 || parent.uid == userID,
                  parent.ttyDevice == process.ttyDevice, parent.startSeconds > 0,
                  parent.startMicroseconds < 1_000_000,
                  parent.startSeconds < process.startSeconds ||
                    (parent.startSeconds == process.startSeconds && parent.startMicroseconds <= process.startMicroseconds)
            else { return nil }
        }
        return Identity(surfaceID: surfaceID, process: process, parent: parent)
    }

    private static func readProcess(pid: Int32) -> ProcessFacts? {
        guard let before = processInfo(pid: pid), let path = executablePath(pid: pid),
              let after = processInfo(pid: pid), executablePath(pid: pid) == path,
              before == after else { return nil }
        return ProcessFacts(pid: before.pid, parentPID: before.parentPID, uid: before.uid,
                            realUID: before.realUID, savedUID: before.savedUID,
                            processGroup: before.processGroup, foregroundGroup: before.foregroundGroup,
                            ttyDevice: before.ttyDevice, startSeconds: before.startSeconds,
                            startMicroseconds: before.startMicroseconds, path: path)
    }

    private static func processInfo(pid: Int32) -> ProcessFacts? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let returnedPID = Int32(exactly: info.pbi_pid), returnedPID == pid,
              let parent = Int32(exactly: info.pbi_ppid),
              let group = Int32(exactly: info.pbi_pgid), let foreground = Int32(exactly: info.e_tpgid) else { return nil }
        return ProcessFacts(pid: returnedPID, parentPID: parent, uid: info.pbi_uid,
                            realUID: info.pbi_ruid, savedUID: info.pbi_svuid,
                            processGroup: group, foregroundGroup: foreground, ttyDevice: info.e_tdev,
                            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, path: "")
    }

    private static func readParent(pid: Int32) -> ParentFacts? {
        // Root login rejects full PROC_PIDTBSDINFO for an ordinary user. The
        // short BSD flavor and KERN_PROC_PID expose the necessary ancestry and
        // start time without launching a process or granting elevated access.
        guard let before = parentInfo(pid: pid), let path = executablePath(pid: pid),
              let after = parentInfo(pid: pid), before == after,
              executablePath(pid: pid) == path else { return nil }
        return ParentFacts(pid: before.pid, parentPID: before.parentPID, uid: before.uid,
                           ttyDevice: before.ttyDevice, startSeconds: before.startSeconds,
                           startMicroseconds: before.startMicroseconds, path: path)
    }

    private static func parentInfo(pid: Int32) -> ParentFacts? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
              info.pbsi_pid == UInt32(pid), let parent = Int32(exactly: info.pbsi_ppid) else { return nil }
        var kernel = kinfo_proc()
        var bytes = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kernel, &bytes, nil, 0) == 0,
              bytes == MemoryLayout<kinfo_proc>.size, kernel.kp_proc.p_pid == pid,
              kernel.kp_eproc.e_ppid == parent, kernel.kp_eproc.e_ucred.cr_uid == info.pbsi_uid,
              let seconds = UInt64(exactly: kernel.kp_proc.p_un.__p_starttime.tv_sec),
              let microseconds = UInt64(exactly: kernel.kp_proc.p_un.__p_starttime.tv_usec) else { return nil }
        return ParentFacts(pid: pid, parentPID: parent, uid: info.pbsi_uid,
                           ttyDevice: UInt32(bitPattern: kernel.kp_eproc.e_tdev),
                           startSeconds: seconds, startMicroseconds: microseconds, path: "")
    }

    private static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable to Swift.
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard count > 0, count < bytes.count else { return nil }
        return String(cString: bytes)
    }
}
