# my-claude-code-settings

## Subagent Model 對照表

這個 repo 會把 Claude Code 的 subagent 定義轉換給 Codex 與 opencode 兩個工具使用，Claude 定義裡的 model tier 會被映射成各平台對應的 model。下表整理這個對照關係，方便快速查閱。

| Claude tier | codex | opencode |
| --- | --- | --- |
| opus | gpt-5.5（reasoning effort: high） | opencode-go/glm-5.2 |
| sonnet | gpt-5.4（reasoning effort: medium） | opencode-go/deepseek-v4-pro |
| haiku | gpt-5.4-mini（reasoning effort: low） | opencode-go/deepseek-v4-flash |
| inherit（或無 model 欄位） | 不輸出 model 欄位，繼承平台預設 model | 不輸出 model 欄位，繼承平台預設 model |

執行 `python3 scripts/agent_model_map.py` 可直接印出這張對照表，該輸出是即時從單一來源產生的。

README 中的這張表是靜態內容，維護時需與 `scripts/agent_model_map.py` 這個單一來源手動保持同步。
