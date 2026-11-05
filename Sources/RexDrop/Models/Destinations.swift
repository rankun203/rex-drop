import AppKit

func orderedTargets(_ targets: [[String: Any]]) -> [[String: Any]] {
    var seen = Set<String>()
    return targets.filter {
        guard ($0["selectable"] as? Bool) != false, ($0["kind"] as? String) != "unsupported", let id = $0["id"] as? String else { return false }
        return seen.insert(id).inserted
    }.sorted {
        let leftSSH = ($0["kind"] as? String) == "ssh", rightSSH = ($1["kind"] as? String) == "ssh"
        if leftSSH != rightSSH { return leftSSH }
        let left = destinationTitle($0)
        let right = destinationTitle($1)
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }
}

func destinationTitle(_ target: [String: Any]) -> String {
    if let display = target["destination_display"] as? String, !display.isEmpty { return display }
    if target["kind"] as? String == "ssh" {
        return (target["display_name"] as? String ?? "SSH") + ":/tmp"
    }
    let detail = target["detail"] as? String ?? ""
    let path = target["destination_path"] as? String ?? detail.components(separatedBy: " · ").last ?? ""
    if path.hasPrefix("/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    return path.isEmpty ? (target["display_name"] as? String ?? target["label"] as? String ?? "Rex") : path
}
