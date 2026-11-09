#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/office-room-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT HUP INT TERM
node tests/team-workflow.test.js
node tests/task-workspace.test.js
node tests/team-integration.test.js
node tests/agent-tracker.test.js
node tests/skill-catalog.test.js
node tests/agent-registry.test.js
node --test tests/claude-usage.test.js tests/codex-usage.test.js
node tests/server-native-integration.test.js
node tests/workflow-integration.test.js
swiftc -module-cache-path "$TEST_BUILD/modules" -o "$TEST_BUILD/NativeTests" app/OfficeStore.swift app/OfficeScene.swift tests/NativeTests.swift -framework Cocoa -framework SceneKit
"$TEST_BUILD/NativeTests"
swiftc -module-cache-path "$TEST_BUILD/modules" -o "$TEST_BUILD/NativeWorkflowTests" app/OfficeStore.swift app/OfficeScene.swift tests/NativeWorkflowTests.swift -framework Cocoa -framework SceneKit
"$TEST_BUILD/NativeWorkflowTests"
swiftc -module-cache-path "$TEST_BUILD/modules" -o "$TEST_BUILD/NativeUITests" app/OfficeStore.swift app/OfficeScene.swift app/NativeUI.swift app/PromptInput.swift tests/NativeUITests.swift -framework Cocoa -framework SwiftUI -framework SceneKit
"$TEST_BUILD/NativeUITests"
swiftc -module-cache-path "$TEST_BUILD/modules" -o "$TEST_BUILD/NativeSkillPickerTests" app/OfficeStore.swift app/OfficeScene.swift app/NativeUI.swift app/PromptInput.swift tests/NativeSkillPickerTests.swift -framework Cocoa -framework SwiftUI -framework SceneKit
"$TEST_BUILD/NativeSkillPickerTests"
swiftc -module-cache-path "$TEST_BUILD/modules" -o "$TEST_BUILD/NativeClipboardTests" app/OfficeStore.swift app/OfficeScene.swift app/NativeUI.swift app/PromptInput.swift tests/NativeClipboardTests.swift -framework Cocoa -framework SwiftUI -framework SceneKit
"$TEST_BUILD/NativeClipboardTests"
