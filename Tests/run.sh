#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
cat > "$TEMP_DIR/config" <<'CONFIG'
apiVersion: v1
kind: Config
clusters: []
users: []
contexts:
- name: development
  context: {}
- name: production with spaces
  context: {}
current-context: development
CONFIG
sed '/^final class AppDelegate/,$d' Sources/main.swift > "$TEMP_DIR/main.swift"
cat >> "$TEMP_DIR/main.swift" <<'SWIFT'
let client = Kubectl()
let initial = client.run(["config", "current-context"])
precondition(initial.status == 0 && initial.output == "development")
let switched = client.run(["config", "use-context", "production with spaces"])
precondition(switched.status == 0)
precondition(client.run(["config", "current-context"]).output == "production with spaces")
let missing = client.run(["config", "use-context", "missing"])
precondition(missing.status != 0 && !missing.error.isEmpty)
precondition(client.run(["config", "current-context"]).output == "production with spaces")
let config = client.run(["config", "view", "-o", "json"])
precondition(config.status == 0)
let parsed = try JSONSerialization.jsonObject(with: Data(config.output.utf8)) as! [String: Any]
precondition((parsed["contexts"] as? [[String: Any]])?.count == 2)
print("PASS: read, switch (including spaces), failure preservation, and configuration parsing")
SWIFT
xcrun swiftc -module-cache-path "$PWD/build/ModuleCache" -swift-version 5 -framework AppKit "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
KUBECONFIG="$TEMP_DIR/config" "$TEMP_DIR/test"
