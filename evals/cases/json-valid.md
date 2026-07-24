---
id: json-valid
type: command
description: プラグインマニフェストと hooks.json が JSON として妥当
run: jq -e . hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json
expect_exit: 0
---
## メモ

hooks.json が壊れると hook が丸ごと無効になり、ゲートが効かないまま気づかない。
