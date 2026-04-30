# PlantUML 標準圖示庫 Include 參考

本檔為 diagram-designer skill 的 reference，僅在使用 PlantUML 並需要 C4 model、AWS / Azure / GCP / Kubernetes 圖示庫時載入。

## 目錄

- [C4-PlantUML](#c4-plantuml)
- [AWS Icons for PlantUML](#aws-icons-for-plantuml)
- [Azure-PlantUML](#azure-plantuml)
- [GCP-PlantUML](#gcp-plantuml)
- [Kubernetes-PlantUML](#kubernetes-plantuml)
- [注意事項](#注意事項)

## C4-PlantUML

Repo：<https://github.com/plantuml-stdlib/C4-PlantUML>

主要 include 檔案：

| 檔案 | 用途 |
| --- | --- |
| `C4_Context.puml` | System context diagram |
| `C4_Container.puml` | Container diagram（最常用） |
| `C4_Component.puml` | Component diagram |
| `C4_Deployment.puml` | Deployment diagram |
| `C4_Dynamic.puml` | Dynamic / runtime view |
| `C4_Sequence.puml` | Sequence flavor of C4 |

Include 範例：

```plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml

Person(user, "User")
Container(web, "Web App", "React")
ContainerDb(db, "Database", "PostgreSQL")
Rel(user, web, "Uses")
Rel(web, db, "Reads/Writes")
@enduml
```

常用 macro：`Person`、`System`、`Container`、`ContainerDb`、`ContainerQueue`、`Component`、`Rel`、`Rel_Back`、`Boundary`、`System_Boundary`、`Enterprise_Boundary`

## AWS Icons for PlantUML

Repo：<https://github.com/awslabs/aws-icons-for-plantuml>（官方）

常用 include：

| 路徑 | 說明 |
| --- | --- |
| `dist/AWSCommon.puml` | 基礎，必須先載入 |
| `dist/AWSSimplified.puml` | 簡化版視覺 |
| `dist/Compute/all.puml` | 整類載入 |
| `dist/Compute/EC2.puml` | 個別服務（EC2） |
| `dist/Database/RDS.puml` | 個別服務（RDS） |
| `dist/Storage/SimpleStorageServiceS3.puml` | 個別服務（S3） |

Include 範例：

```plantuml
@startuml
!include https://raw.githubusercontent.com/awslabs/aws-icons-for-plantuml/main/dist/AWSCommon.puml
!include https://raw.githubusercontent.com/awslabs/aws-icons-for-plantuml/main/dist/Compute/EC2.puml
!include https://raw.githubusercontent.com/awslabs/aws-icons-for-plantuml/main/dist/Database/RDS.puml

EC2(web, "Web Server", "t3.medium")
RDS(db, "Database", "MySQL")
web --> db
@enduml
```

## Azure-PlantUML

Repo：<https://github.com/plantuml-stdlib/Azure-PlantUML>

常用 include：

- `dist/AzureCommon.puml`（必須先載入）
- `dist/AzureSimplified.puml`（簡化版視覺）
- 各分類底下的 `all.puml` 或個別服務 puml

Include 範例：

```plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/Azure-PlantUML/master/dist/AzureCommon.puml
!include https://raw.githubusercontent.com/plantuml-stdlib/Azure-PlantUML/master/dist/Compute/AzureVirtualMachine.puml

AzureVirtualMachine(vm, "VM", "Standard_D2s_v3")
@enduml
```

## GCP-PlantUML

Repo：<https://github.com/davidholsgrove/gcp-icons-for-plantuml>（社群維護，較完整）

Include 範例：

```plantuml
@startuml
!include https://raw.githubusercontent.com/davidholsgrove/gcp-icons-for-plantuml/master/dist/GCPCommon.puml
!include https://raw.githubusercontent.com/davidholsgrove/gcp-icons-for-plantuml/master/dist/Compute/GCPComputeEngine.puml

GCPComputeEngine(vm, "Compute Engine", "n2-standard-2")
@enduml
```

此 repo 為社群維護，若官方有更新版本需自行確認。

## Kubernetes-PlantUML

Repo：<https://github.com/dcasati/kubernetes-PlantUML>

Include 範例：

```plantuml
@startuml
!include https://raw.githubusercontent.com/dcasati/kubernetes-PlantUML/master/dist/kubernetes-PlantUML.iuml

KubernetesPod(pod, "API Pod")
KubernetesService(svc, "Service")
KubernetesDeployment(deploy, "Deployment")
svc --> pod
deploy --> pod
@enduml
```

常用 macro：`KubernetesPod`、`KubernetesService`、`KubernetesDeployment`、`KubernetesConfigMap`、`KubernetesSecret`、`KubernetesNamespace`

terrastruct icons 沒有完整的 Kubernetes 圖示庫，這是 PlantUML 的相對優勢。

## 注意事項

- `!include` 使用 `raw.githubusercontent.com` URL 時，須選對 branch（通常為 `master` 或 `main`，不同 repo 不同，需確認）
- 透過 kroki.io 渲染時，PlantUML server 會自動處理 `!include`，不需要本機安裝任何圖示庫
- 若 `!include` 失敗，先確認 URL 在瀏覽器中可正常開啟，再排查 branch 名稱或路徑是否正確
