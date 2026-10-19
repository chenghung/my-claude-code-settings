# 專案指示

本 repo 專屬的指示寫在本檔，供 Claude Code、Codex、OpenCode、Antigravity 共用。根目錄的 `CLAUDE.md` 是 `install.sh` 部署到各 CLI 的全域指示來源，套用到所有專案。

## 檢查與測試

本機與 CI 共用同一個入口，從任何目錄呼叫皆可：

```sh
scripts/run-checks.sh             # shellcheck 與 tests 全跑
scripts/run-checks.sh shellcheck  # 只跑 shellcheck
scripts/run-checks.sh test        # 只跑 tests
```

- 一律透過這支腳本跑檢查：它固定以 bash 執行，結果與 CI 一致；把迴圈抄到 zsh 裡跑，未加引號的變數不會被拆成多個參數。
- CI 的 `shellcheck` 與 `test` 兩個 job 分別呼叫對應子命令；`tests/` 與 `hooks/tests/` 下的 `*.sh` 與 `*.bats` 會自動納入，新增測試不需修改 CI。
- 需要 `shellcheck`（CI 釘選 v0.11.0）與 `bats`，部分測試另需 `zsh`。
