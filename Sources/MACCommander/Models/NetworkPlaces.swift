import AppKit
import Foundation
import NetFS

/// Another computer on the Tailscale network.
struct NetworkComputer: Equatable {
    let name: String
    /// Its Tailscale address, which works whether or not Tailscale's DNS names do.
    let address: String
}

/// Other computers: the Tailscale list, a computer's shared folders, and mounting a share.
///
/// Paths to another computer are written `smb://server` (its list of shares) and
/// `smb://server/share/rest`. A share is mounted the macOS way, under /Volumes, and the
/// pane then shows that folder, so everything works there as it does on this Mac.
enum NetworkPlaces {
    // MARK: - Paths

    private static func strip(_ path: String) -> Substring? {
        let lower = path.lowercased()
        if lower.hasPrefix("smb://") { return path.dropFirst(6) }
        if path.hasPrefix("//") { return path.dropFirst(2) }
        if path.hasPrefix("\\\\") { return Substring(path.dropFirst(2).replacingOccurrences(of: "\\", with: "/")) }
        return nil
    }

    /// `smb://server` on its own: a computer's list of shares.
    static func serverOnly(_ path: String) -> String? {
        guard let rest = strip(path) else { return nil }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count == 1 ? String(parts[0]) : nil
    }

    /// `smb://server/share/rest`, taken apart.
    static func shareParts(_ path: String) -> (server: String, share: String, rest: String)? {
        guard let rest = strip(path) else { return nil }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.dropFirst(2).joined(separator: "/"))
    }

    // MARK: - Mounted shares

    /// Where a share is already mounted, if it is.
    static func mountPoint(server: String, share: String) -> String? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            guard let remote = (try? volume.resourceValues(forKeys: Set(keys)))?.volumeURLForRemounting,
                  let host = remote.host else { continue }
            let remoteShare = remote.path.split(separator: "/").first.map(String.init) ?? ""
            if host.caseInsensitiveCompare(server) == .orderedSame,
               remoteShare.removingPercentEncoding?.caseInsensitiveCompare(share) == .orderedSame
                || remoteShare.caseInsensitiveCompare(share) == .orderedSame {
                return volume.path
            }
        }
        return nil
    }

    /// The computer a folder is the mounted root of a share from, so ".." there goes back
    /// to that computer's list of shares.
    static func serverOfMountRoot(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeURLForRemountingKey]),
              let volume = values.volume, Paths.same(volume.path, path),
              let remote = values.volumeURLForRemounting,
              remote.scheme?.lowercased() == "smb" else { return nil }
        return remote.host
    }

    /// Makes sure a share can be got at. Already mounted: its folder, at once. Otherwise
    /// the mount is started in the background, macOS asks for a login itself if one is
    /// needed, and `whenMounted` is called with the folder once it is there.
    static func reach(server: String, share: String, name: String, warn: @escaping (String) -> Void,
                      whenMounted: ((String) -> Void)? = nil) -> String? {
        if let mounted = mountPoint(server: server, share: share) { return mounted }

        guard answers(server) else {
            warn("Cannot open \(name):\nThe computer is off, asleep, or not sharing files.\n\nsmb://\(server)/\(share)")
            return nil
        }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = server
        components.path = "/" + share
        guard let url = components.url else { return nil }

        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var requestID: AsyncRequestID?
        _ = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil, &requestID, DispatchQueue.main) { status, _, mountpoints in
            guard status == 0, let points = mountpoints as? [String], let first = points.first else {
                if status != 0 && status != Int32(ECANCELED) && status != -128 {
                    warn("Cannot open \(name):\n\(describe(status))\n\nsmb://\(server)/\(share)")
                }
                return
            }
            whenMounted?(first)
            NotificationCenter.default.post(name: .shareMounted, object: nil,
                                            userInfo: ["server": server, "share": share, "path": first])
        }
        return nil
    }

    static func describe(_ status: Int32) -> String {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM): return "The login was refused."
        case Int32(ENOENT): return "There is no shared folder of that name."
        case Int32(EHOSTUNREACH), Int32(ETIMEDOUT): return "The computer does not answer."
        default: return String(cString: strerror(status))
        }
    }

    /// Whether the computer answers on the file-sharing port, asked with a short time
    /// limit: the system takes half a minute to give up on one that is off.
    static func answers(_ server: String, timeout: TimeInterval = 3) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "445", &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    // MARK: - Shares

    /// A computer's shared folders. Hidden ones ending in `$` are left out, except whole
    /// drives such as `C$`, which are listed with the shares.
    static func listShares(server: String) throws -> [String] {
        guard answers(server) else {
            throw NSError(domain: "MACCommander", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The computer is off, asleep, or not sharing files."])
        }
        // -N: never ask for a password here. A login remembered in the keychain is used.
        let (status, output, error) = run("/usr/bin/smbutil", ["view", "-N", "//\(server)"], timeout: 8)
        guard status == 0 else {
            let reason = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MACCommander", code: 2, userInfo: [NSLocalizedDescriptionKey:
                (reason.isEmpty ? "The computer would not list its shared folders." : reason)
                + "\n\nA shared folder can still be opened by typing smb://\(server)/<name> into the path box."])
        }
        var shares: [String] = []
        for line in output.split(separator: "\n") {
            // "Share        Type    Comments" then rows of "name   Disk   comment"
            let text = String(line)
            guard let range = text.range(of: #"\s+Disk(\s|$)"#, options: .regularExpression) else { continue }
            let name = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let isDrive = name.count == 2 && name.hasSuffix("$") && name.first!.isLetter
            if name.hasSuffix("$") && !isDrive { continue }
            shares.append(name)
        }
        return shares.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Tailscale

    private static let tailscaleCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// The computers Tailscale says are online, other than this one. Without Tailscale it
    /// simply has none to offer.
    static func tailscaleComputers(timeout: TimeInterval = 5) -> [NetworkComputer] {
        guard let tool = tailscaleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return [] }
        let (status, output, _) = run(tool, ["status", "--json"], timeout: timeout)
        guard status == 0, let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: [String: Any]] else { return [] }

        var found: [NetworkComputer] = []
        for peer in peers.values {
            guard (peer["Online"] as? Bool) == true,
                  let ips = peer["TailscaleIPs"] as? [String],
                  let address = ips.first(where: { !$0.contains(":") }) else { continue }
            let os = (peer["OS"] as? String ?? "").lowercased()
            // phones and tablets share no folders
            if os == "ios" || os == "android" { continue }
            var name = peer["HostName"] as? String ?? ""
            if name.isEmpty, let dns = peer["DNSName"] as? String {
                name = String(dns.split(separator: ".").first ?? "")
            }
            found.append(NetworkComputer(name: name.isEmpty ? address : name, address: address))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Running tools

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }

        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self),
                String(decoding: stderr, as: UTF8.self))
    }
}

extension Notification.Name {
    static let shareMounted = Notification.Name("MACCommander.shareMounted")
}
