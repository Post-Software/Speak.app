import Foundation

enum PythonRuntimeEnvironment {
    static func makeEnvironment(
        for pythonURL: URL,
        additionalPythonPaths: [String] = [],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["PIP_NO_CACHE_DIR"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["NO_COLOR"] = "1"
        if let pythonHome = bundledPythonHome(for: pythonURL) {
            env["PYTHONHOME"] = pythonHome
        }
        if !additionalPythonPaths.isEmpty {
            var merged = additionalPythonPaths
            if let existing = env["PYTHONPATH"], !existing.isEmpty {
                merged.append(existing)
            }
            env["PYTHONPATH"] = merged.joined(separator: ":")
        }
        return env
    }

    static func bundledPythonHome(for pythonURL: URL) -> String? {
        // Resolve from .../python/bin/python[3] -> .../python
        let pythonRoot = pythonURL.deletingLastPathComponent().deletingLastPathComponent()
        let versionsDir = pythonRoot
            .appendingPathComponent("Python.framework", isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)

        guard isDirectory(versionsDir) else { return nil }

        if let current = currentVersionDirectory(in: versionsDir) {
            return current.path
        }

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: versionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if candidate.lastPathComponent == "Current" { continue }
            if isDirectory(candidate) {
                return candidate.path
            }
        }

        return nil
    }

    private static func currentVersionDirectory(in versionsDir: URL) -> URL? {
        let current = versionsDir.appendingPathComponent("Current", isDirectory: true)
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }

        if let symlinkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
            let resolved: URL
            if symlinkTarget.hasPrefix("/") {
                resolved = URL(fileURLWithPath: symlinkTarget, isDirectory: true)
            } else {
                resolved = versionsDir.appendingPathComponent(symlinkTarget, isDirectory: true)
            }
            if isDirectory(resolved) {
                return resolved.standardizedFileURL
            }
        }

        if isDirectory(current) {
            return current.standardizedFileURL
        }

        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
