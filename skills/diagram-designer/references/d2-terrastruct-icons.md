# d2 Terrastruct Icons Reference

本檔為 diagram-designer skill 的 reference 索引檔，僅在使用 d2 並需要 terrastruct icons 時載入。實際 icon 清單分散在 `d2-terrastruct-icons/` 子目錄下，依需要再載入對應 provider 的子檔。

## 目錄

- [URL Pattern](#url-pattern)
- [d2 使用語法](#d2-使用語法)
- [Provider 一覽與載入指引](#provider-一覽與載入指引)
- [未涵蓋的 Provider](#未涵蓋的-provider)
- [Kubernetes Icons 特別提醒](#kubernetes-icons-特別提醒)
- [找不到 Icon 時的處理流程](#找不到-icon-時的處理流程)

## URL Pattern

完整 URL 格式：

```text
https://icons.terrastruct.com/<provider>/<category>/<icon-name>.svg
```

URL 編碼規則：路徑中的空格須編碼為 `%20`，`&` 編碼為 `%26`，`,` 編碼為 `%2C`。

範例：本地相對路徑 `aws/Networking & Content Delivery/AWS-Cloud-Map.svg` 對應的完整 URL 為：

```text
https://icons.terrastruct.com/aws/Networking%20%26%20Content%20Delivery/AWS-Cloud-Map.svg
```

## d2 使用語法

```d2
ec2: {
  shape: image
  icon: https://icons.terrastruct.com/aws/Compute/Amazon-EC2.svg
}
```

## Provider 一覽與載入指引

| Provider | 子檔路徑 | icon 數 | 觸發載入時機 |
| --- | --- | --- | --- |
| aws | `d2-terrastruct-icons/aws.md` | 256 | 設計 AWS 架構圖時 |
| azure | `d2-terrastruct-icons/azure.md` | 262 | 設計 Azure 架構圖時 |
| gcp | `d2-terrastruct-icons/gcp.md` | 109 | 設計 GCP 架構圖時 |
| dev | `d2-terrastruct-icons/dev.md` | 123 | 需要 docker、git、語言 / 框架 logo 時 |
| essentials | `d2-terrastruct-icons/essentials.md` | 100 | 需要通用 UI 圖示（資料庫、伺服器、使用者等）時 |

## 未涵蓋的 Provider

terrastruct 另有 tech、infra、social、emotions 等 provider，本 skill 暫未為其建立子檔。若需要可直接前往 <https://icons.terrastruct.com> 搜尋，URL pattern 同上。

## Kubernetes Icons 特別提醒

terrastruct 沒有獨立的 k8s/kubernetes provider。Kubernetes 相關 icon 散落於以下位置：

- `aws/Compute/Amazon-Elastic-Kubernetes-Service.svg`
- `azure/_Companies/Kubernetes.svg`
- `azure/Container Service Color/Kubernetes Services.svg`

若需完整 Kubernetes 原生 icon 集，建議改用 PlantUML 的 Kubernetes 圖示庫（見 `plantuml-stdlib-includes.md`）。

## 找不到 Icon 時的處理流程

1. 先依 provider/category 結構推測檔名，例如 RDS 試 `aws/Database/Amazon-RDS.svg`
1. 推測 URL 在 kroki.io 預覽 URL 中渲染失敗時，改前往 <https://icons.terrastruct.com> 直接搜尋
