import Foundation

/// Starter packages for "New package" (Developer mode) and `lasso-pkg new`: each one valid as is, so
/// an author starts from something that runs and changes it.
enum PackageStarters {
    enum Kind: String, CaseIterable, Sendable {
        case search, send, prompt, shortcut, script

        var title: String {
            switch self {
            case .search: "Web search source"
            case .send: "Send to a service"
            case .prompt: "Button that asks your model"
            case .shortcut: "Run one of your Shortcuts"
            case .script: "Script on your Mac"
            }
        }
    }

    /// The files of a starter, by path (`lasso.json` included).
    static func files(_ kind: Kind, id: String) -> [String: String] {
        let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let head = """
          "lasso": 1, "id": "\(id)", "version": "1.0.0", "name": "\(name)",
          "author": "Your name",
        """
        let manifest: String
        var files: [String: String] = [:]
        var readme = "# \(name)\n\nWhat it does, what it sends where, and what it needs (a key, a tool, a Shortcut).\n"
        switch kind {
        case .search:
            manifest = """
            {
            \(head)
              "summary": "Adds results from example.com to Lasso's web search.",
              "hosts": ["api.example.com"],
              "settings": [ { "id": "key", "label": "API key", "kind": "secret", "help": "https://example.com/keys" } ],
              "limits": { "monthly": 1000 },
              "commands": [ {
                "id": "search", "title": "\(name)", "surfaces": ["search"], "input": ["query"], "output": "results",
                "run": {
                  "http": { "url": "https://api.example.com/search", "query": { "q": "{{query}}" },
                            "headers": { "Authorization": "Bearer {{settings.key}}" } },
                  "results": { "list": "results", "title": "title", "url": "url", "snippet": "snippet" },
                  "role": "reserve"
                },
                "test": { "query": "lasso app" }
              } ]
            }
            """
            readme += "\nSends your web searches to api.example.com with your API key.\n"
        case .send:
            manifest = """
            {
            \(head)
              "summary": "Sends what you lasso to example.com.",
              "hosts": ["api.example.com"],
              "settings": [ { "id": "key", "label": "API key", "kind": "secret" } ],
              "commands": [ {
                "id": "send", "title": "Send to \(name)", "symbol": "paperplane", "surfaces": ["send"],
                "input": ["text"], "output": "notify",
                "run": {
                  "http": { "method": "POST", "url": "https://api.example.com/items",
                            "headers": { "Authorization": "Bearer {{settings.key}}" }, "json": { "text": "{{text}}" } },
                  "answer": "message"
                }
              } ]
            }
            """
            readme += "\nSends the text you choose to api.example.com with your API key.\n"
        case .prompt:
            manifest = """
            {
            \(head)
              "summary": "Explains anything you lasso, simply.",
              "commands": [ {
                "id": "explain", "title": "Explain simply", "symbol": "lightbulb", "surfaces": ["toolbar", "slash"],
                "input": ["text"], "when": { "minLength": 20 }, "output": "markdown",
                "run": { "prompt": "Explain this simply, in a few short sentences:\\n\\n{{text}}" },
                "test": { "text": "Photosynthesis converts light energy into chemical energy stored in glucose." }
              } ]
            }
            """
            readme += "\nSends the text you run it on to the model chosen in Lasso's Settings, nowhere else.\n"
        case .shortcut:
            manifest = """
            {
            \(head)
              "summary": "Sends what you lasso to one of your Shortcuts.",
              "commands": [ {
                "id": "run", "title": "\(name)", "symbol": "square.on.square", "surfaces": ["send"],
                "input": ["text"], "output": "notify",
                "run": { "shortcut": { "name": "\(name) from Lasso", "offline": false } }
              } ]
            }
            """
            readme += "\nRuns your Shortcut \"\(name) from Lasso\" with the text. Make it in the Shortcuts app first, taking Text as input.\n"
        case .script:
            manifest = """
            {
            \(head)
              "summary": "Counts the words in what you lasso.",
              "commands": [ {
                "id": "count", "title": "Count words", "symbol": "number", "surfaces": ["toolbar", "slash"],
                "input": ["text"], "output": "markdown",
                "run": { "script": { "path": "scripts/count.py", "timeout": 10 } },
                "test": { "text": "One two three." }
              } ]
            }
            """
            files["scripts/count.py"] = """
            #!/usr/bin/env python3
            # Lasso writes one JSON object to standard input and reads the answer from standard output.
            import json, sys
            data = json.load(sys.stdin)
            words = len(data["text"].split())
            print(json.dumps({"text": f"**{words}** words"}))

            """
            readme += "\nRuns scripts/count.py on your Mac, in Lasso's sandbox. It sends nothing anywhere.\n"
        }
        files["lasso.json"] = manifest + "\n"
        files["README.md"] = readme
        return files
    }

    /// Writes a starter into `folder` (which must not exist yet).
    static func write(_ kind: Kind, id: String, to folder: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path])
        }
        for (path, contents) in files(kind, id: id) {
            let url = folder.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            if path.hasPrefix("scripts/") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }
}

/// A package as one file to share or download: `{"lassopkg": 1, "manifest": base64, "files": {path: base64}}`.
/// The manifest's exact bytes are kept, so its hash is the same everywhere.
enum PackageBundle {
    static let fileExtension = "lassopkg"

    static func pack(manifest: Data, files: PackageFiles.Files) throws -> Data {
        let object: [String: Any] = ["lassopkg": 1, "manifest": manifest.base64EncodedString(),
                                     "files": files.mapValues { $0.base64EncodedString() }]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func unpack(_ data: Data) -> (manifest: Data, files: PackageFiles.Files)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["lassopkg"] as? Int == 1,
              let manifest = (object["manifest"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let raw = object["files"] as? [String: String] else { return nil }
        var files: PackageFiles.Files = [:]
        for (path, value) in raw {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(""), path != "lasso.json",
                  let bytes = Data(base64Encoded: value) else { return nil }
            files[path] = bytes
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= PackageFiles.maxFolderBytes else { return nil }
        return (manifest, files)
    }
}
