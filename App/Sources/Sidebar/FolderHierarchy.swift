import Foundation
import MailternalInterfaces

/// A folder and the folders whose parent path resolves to it.
struct FolderHierarchyNode: Identifiable, Hashable {
    let folder: FolderSummary
    let children: [FolderHierarchyNode]

    var id: FolderID { folder.id }
}

enum FolderHierarchy {
    /// Builds a forest from mailbox paths using each folder's persisted delimiter.
    ///
    /// A parent is found only when the folder's separator is present immediately
    /// before its terminal display name. Missing or malformed separator metadata
    /// leaves the folder at the root instead of inventing a parent.
    static func make(from folders: [FolderSummary]) -> [FolderHierarchyNode] {
        guard !folders.isEmpty else { return [] }

        var pathOwners: [String: FolderID] = [:]
        for folder in folders {
            // Duplicate server paths are malformed; keep the first stable owner and
            // leave later folders as roots rather than attaching them unpredictably.
            if pathOwners[folder.path] == nil {
                pathOwners[folder.path] = folder.id
            }
        }

        var parentByID: [FolderID: FolderID] = [:]
        for folder in folders {
            guard let parentPath = parentPath(
                for: folder.path,
                name: folder.name,
                separator: folder.separator
            ),
                  let parentID = pathOwners[parentPath], parentID != folder.id else {
                continue
            }
            // Refuse cycles defensively. IMAP paths should form a tree, but malformed
            // input must not make recursive rendering overflow.
            var ancestor = parentID
            var visited: Set<FolderID> = [folder.id]
            var createsCycle = false
            while let next = parentByID[ancestor] {
                if !visited.insert(ancestor).inserted {
                    createsCycle = true
                    break
                }
                ancestor = next
            }
            if !createsCycle && !visited.contains(ancestor) {
                parentByID[folder.id] = parentID
            }
        }

        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var childrenByParent: [FolderID: [FolderSummary]] = [:]
        var roots: [FolderSummary] = []
        for folder in folders {
            if let parentID = parentByID[folder.id], foldersByID[parentID] != nil {
                childrenByParent[parentID, default: []].append(folder)
            } else {
                roots.append(folder)
            }
        }

        func makeNode(_ folder: FolderSummary) -> FolderHierarchyNode {
            let children = (childrenByParent[folder.id] ?? [])
                .sorted(by: folderOrdering)
                .map(makeNode)
            return FolderHierarchyNode(folder: folder, children: children)
        }

        return roots.sorted(by: folderOrdering).map(makeNode)
    }

    /// Returns the actual parent path only when the persisted hierarchy
    /// separator immediately precedes the terminal display name.
    /// For a leading delimiter, the delimiter itself is the root path
    /// (`/child` -> `/`).
    static func parentPath(for path: String, name: String, separator: Character?) -> String? {
        guard let separator,
              !name.isEmpty,
              path.hasSuffix(name),
              let nameStart = path.index(
                  path.endIndex,
                  offsetBy: -name.count,
                  limitedBy: path.startIndex
              ),
              nameStart > path.startIndex else {
            return nil
        }
        let delimiterIndex = path.index(before: nameStart)
        guard path[delimiterIndex] == separator else { return nil }
        let prefix = String(path[..<delimiterIndex])
        return prefix.isEmpty ? String(separator) : prefix
    }

    private static func folderOrdering(_ lhs: FolderSummary, _ rhs: FolderSummary) -> Bool {
        if roleRank(lhs.role) != roleRank(rhs.role) {
            return roleRank(lhs.role) < roleRank(rhs.role)
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func roleRank(_ role: FolderRole) -> Int {
        switch role {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .archive: 3
        case .junk: 4
        case .trash: 5
        case .none: 6
        }
    }
}
