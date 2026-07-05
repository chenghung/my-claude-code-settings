---
name: python
description: >
  當需要產生、修改或重構 Python 程式碼時觸發，統籌一套以 TDD 撰寫 Python
  並自動進行獨立程式碼審查的流程：先委派撰寫、再自動委派審查、審查發現的
  問題退回修正，如此反覆直到收斂。純粹閱讀或解說既有 Python 程式碼而不加
  以修改的唯讀任務不觸發。觸發關鍵字：python、.py 副檔名、寫 Python、
  修改 Python、重構 Python、Python 程式碼。
---

# Python Skill

## 定位

此 skill 只負責觸發判斷與委派編排，main agent 本身不直接撰寫 Python 程式碼，也不自行審查程式碼。實際的撰寫工作交給 `python-developer` subagent，實際的審查工作交給 `python-code-reviewer` subagent。

本 skill 是所有 Python 撰寫、修改、重構任務的統一入口；main agent 遇到這類任務時應經由本 skill 進入，不應繞過本 skill 直接呼叫底層的撰寫或審查 subagent，否則會跳過「自動獨立審查、findings 退回修正」的迴圈，使本 skill 的設計目的失效。

## 觸發時機

應觸發：

- 需要產生新的 Python 程式碼
- 需要修改既有的 Python 程式碼
- 需要重構既有的 Python 模組

不應觸發：

- 純粹閱讀、解說或理解既有 Python 程式碼而不加以修改的唯讀任務
- Python 以外語言的任務

## 執行流程

1. 將撰寫任務連同需求、目標檔案與專案脈絡委派給 `python-developer`，由其以 TDD 完成程式碼。
1. 程式碼完成後，自動將產出委派給 `python-code-reviewer` 進行獨立審查，並指明要審查的檔案或變更範圍。
1. 若審查判定為 `changes-recommended`，將其 findings 退回 `python-developer` 修正。
1. 修正迴圈的結束條件：當審查回傳 `pass`，或僅剩經 main agent 與使用者判斷可接受的非必要 findings 時結束。為避免無限迴圈，回合數應有節制，多輪仍無法收斂時由 main agent 停下，將剩餘 findings 呈報使用者決定。

## 委派原則

委派給 `python-developer` 與 `python-code-reviewer` 時，只描述任務目標、意圖與所需事實（例如目標檔案路徑、需求、要審查的範圍），不指定 subagent 內部應使用哪些工具、指令或執行步驟；具體實作由 subagent 自行決定。
