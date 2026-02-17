# コスト分析: 検証環境のコスト最適化

本ドキュメントは、本サンプルプロジェクトの AWS 構成についてのコスト分析です。料金はリージョンにより異なります。以下は us-east-1 をベースとした目安です（2026 年 2 月時点）。

---

## 1. Lambda の予約同時実行数

### 1.1 現在の設定

| 項目 | 値 | 参照 |
|------|-----|------|
| ReservedConcurrentExecutions | **1** | `templates/bedrock-kb-stream-ingest.yml`（本プロジェクトで採用済み） |
| タイムアウト | 900秒（14分上限のため実質14分） | 同上 |
| boto3 | Lambda レイヤー（boto3 >= 1.42.46、`scripts/build-boto3-layer.sh` で作成） | ランタイム時の pip install なし |
| イベントソース | Amazon MSK（1トピック `streamtopic`） | Lambda コード内 `event['records']['streamtopic-0']` |

### 1.2 本プロジェクトでの実質的な同時実行数

- **トピック**: `streamtopic` のみ。**パーティション**: コード上 `streamtopic-0` のみ参照 → 実質 1 パーティション。
- Lambda はパーティションごとにシーケンシャルにメッセージを読み、1バッチ処理が終わってから次を処理する。
- 本プロジェクトでは **1** を採用しており、1トピック・1パーティションの負荷に対して十分である。boto3 は Lambda レイヤーで提供しており、コールドスタート・実行時間の短縮に寄与する。

---

## 2. MSK プロビジョンドと Serverless の料金比較

料金はリージョンにより異なります。以下は [AWS MSK 料金](https://aws.amazon.com/msk/pricing/) に基づく目安です。

**MSK プロビジョンド（Standard ブローカー）の主な単価**

| 課金項目 | 単価（目安） |
|----------|--------------|
| ブローカー（kafka.t3.small） | 約 $0.021/時間/ブローカー |
| ストレージ | $0.10/GB-月 |

**MSK Serverless の主な単価**

| 課金項目 | 単価（目安） |
|----------|--------------|
| クラスター時間 | $0.75/クラスター時間 |
| パーティション時間 | $0.0015/パーティション時間 |
| データイン | $0.10/GB、データアウト $0.05/GB |
| ストレージ | $0.10/GB-月 |

**本プロジェクト相当の月額概算（24時間稼働・1トピック・1パーティション・低トラフィック想定）**

| 項目 | MSK プロビジョンド（現構成） | MSK Serverless |
|------|------------------------------|----------------|
| ブローカー/クラスター | 2 × 730時間 × $0.021 ≒ **$31** | 730時間 × $0.75 = **$548** |
| パーティション | （ブローカーに含む） | 730 × 1 × $0.0015 ≒ **$1** |
| ストレージ（例: 10 GB） | 10 × $0.10 = **$1** | 同左 ≒ **$1** |
| **月額合計の目安** | **約 $32～35** | **約 $550 以上** |

常時稼働のサンプル・検証用途ではプロビジョンドの方がはるかに安い。本プロジェクトではプロビジョンドのまま運用し、**使わない期間はスタック削除**するのがコスト面で有利。

---

## 3. NAT Gateway

### 3.1 現状のコスト

| 課金項目 | 単価 | 月額概算（24 時間稼働） |
|----------|------|----------------------|
| NAT Gateway 時間料金 | $0.045/時間 | 730h × $0.045 = **$32.85** |
| データ処理料金 | $0.045/GB | 検証用途で低トラフィック ≒ **$0.50** |
| **小計** | | **約 $33** |

参照: [Amazon VPC Pricing](https://aws.amazon.com/vpc/pricing/)

### 3.2 NAT Gateway が必要な理由

現在のアーキテクチャで NAT Gateway を経由するトラフィック:

- **Lambda → Bedrock Agent API**（`ingest_knowledge_base_documents()`）
- **SageMaker Studio → AWS API 各種**（MSK, Lambda, CloudFormation, Bedrock）
- **SageMaker Studio → インターネット**（`pip install confluent-kafka` 等のパッケージインストール）

### 3.3 VPC エンドポイントへの置換は非推奨

VPC Interface Endpoint の料金は $0.01/時間/AZ。Lambda と SageMaker Studio が必要とする AWS サービスエンドポイントを合計すると Interface Endpoint × 6 + Gateway Endpoint × 1 が必要になる。

| 項目 | 計算 | 月額 |
|------|------|------|
| Interface Endpoint × 6、2 AZ | 6 × 2 AZ × $0.01/h × 730h | **$87.60** |
| Gateway Endpoint（S3） | 無料 | **$0.00** |
| **合計** | | **約 $87.60** |

参照: [AWS PrivateLink Pricing](https://aws.amazon.com/privatelink/pricing/)

VPC エンドポイントへの完全置換は **$87.60 vs $33.00** でコスト増。さらに SageMaker Studio の pip install がインターネットアクセスを必要とするため、NAT Gateway を完全に排除するのは困難。検証環境では **NAT Gateway 維持 + スタック削除運用**が最もコスト効率が良い。

---

## 4. Elastic IP

### 4.1 現状のコスト

2024 年 2 月以降、すべてのパブリック IPv4 アドレスに時間料金が適用されている。

| 課金項目 | 単価 | 月額概算 |
|----------|------|---------|
| パブリック IPv4 アドレス（in-use） | $0.005/時間 | 730h × $0.005 = **$3.65** |

参照: [Amazon VPC Public IPv4 Address Pricing](https://aws.amazon.com/vpc/pricing/)

Elastic IP は NAT Gateway に紐づいているため、NAT Gateway と一体でライフサイクル管理する。スタック削除時に Elastic IP も解放されるため、単独での最適化余地はない。

---

## 5. SageMaker Studio

### 5.1 現状のコスト

| 課金項目 | 単価 | 月額概算 |
|----------|------|---------|
| Studio Domain | 無料 | $0.00 |
| JupyterLab インスタンス（ml.t3.medium） | 約 $0.05/時間 | 使用時間依存 |
| EBS ストレージ（5 GB、gp3） | $0.08/GB/月 | 5 × $0.08 = **$0.40** |

参照: [Amazon SageMaker AI Pricing](https://aws.amazon.com/sagemaker/ai/pricing/)

**使用パターン別コスト**:

| パターン | JupyterLab 使用時間 | 月額概算 |
|---------|-------------------|---------|
| 毎日 8h × 20 日（活発利用） | 160h | 160h × $0.05 + $0.40 = **$8.40** |
| 週 2 回 × 4h | 32h | 32h × $0.05 + $0.40 = **$2.00** |
| セットアップ時のみ（1 回） | 2h | $0.10 + $0.40 = **$0.50** |

### 5.2 ローカル Jupyter Notebook への移行可否

| 比較項目 | SageMaker Studio | ローカル Jupyter |
|---------|-----------------|-----------------|
| コスト | $0.50～$8.40/月 + NAT Gateway 間接費 | $0（自前 PC を使用） |
| VPC 内 MSK アクセス | 可能（VpcOnly モード） | 不可（VPN/踏み台が必要） |
| AWS API アクセス | IAM ロール自動 | AWS CLI プロファイル設定が必要 |
| 本サンプルとの互換性 | 完全互換 | ノートブックの一部変更が必要 |

`2.StreamIngest.ipynb` は confluent-kafka Producer で MSK クラスターに直接接続するため、VPC 内の SageMaker Studio が必要。ローカル Jupyter からはプライベートサブネット内の MSK に直接アクセスできない。

### 5.3 推奨

SageMaker Studio は本サンプルの忠実な再現に必要。**JupyterLab のアイドルシャットダウン**（Lifecycle Configuration）を設定し、未使用時のインスタンス課金を自動停止するのが有効。デフォルトでは手動シャットダウンのため、閉じ忘れによる無駄な課金が発生しやすい。

---

## 6. CloudWatch Logs（MSK ブローカーログ）

### 6.1 現状のコスト

| 課金項目 | 単価 | 備考 |
|----------|------|------|
| Vended Logs 取り込み | $0.50/GB（最初の 10 TB） | |
| ログストレージ | $0.03/GB/月 | RetentionInDays: 7 |
| **Free Tier** | 5 GB/月 | |

参照: [Amazon CloudWatch Pricing](https://aws.amazon.com/cloudwatch/pricing/)

kafka.t3.small × 2 ブローカー・低トラフィックの検証用途では、ブローカーログ量は約 0.5～2 GB/月。**Free Tier（5 GB）内に収まる可能性が高い**。

### 6.2 判定

RetentionInDays: 7 は検証環境に適切。これ以上短くするとトラブルシューティング時にログが残らないリスクがある。ログ無効化はデバッグ困難になるため非推奨。**現状で最適化済み**。

---

## 7. Bedrock Knowledge Base（ベクトルストア）

### 7.1 Titan Text Embeddings V2 の API コスト

| 課金項目 | 単価 |
|----------|------|
| 入力トークン | $0.02/100 万トークン |

参照: [Amazon Bedrock Pricing](https://aws.amazon.com/bedrock/pricing/)

本サンプルのペイロード例: "At 2026-02-15 10:30:00 the price of AAPL is 150.25." ≒ 約 20 トークン。仮に 100 レコード × 20 トークン = 2,000 トークンで、コストは $0.00004。**事実上ゼロ**。

### 7.2 ベクトルストア: Amazon S3 Vectors

本プロジェクトでは Amazon S3 Vectors をベクトルストアとして採用する。S3 Vectors は 2025 年 12 月に GA となったベクトルストレージ機能で、Bedrock Knowledge Bases のベクトルストアとして正式にサポートされている。最小課金要件や OCU の概念がなく、完全従量課金のため、検証用途では他の選択肢と比較して桁違いに安価である。

参照: [Amazon S3 Vectors](https://aws.amazon.com/s3/features/vectors/)、[Using S3 Vectors with Amazon Bedrock Knowledge Bases](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-vectors-bedrock-kb.html)

**S3 Vectors の主な単価（us-east-1）**

| 課金項目 | 単価 |
|----------|------|
| ストレージ | $0.06/GB/月 |
| PUT 操作 | $0.20/GB（論理 GB あたり） |
| クエリ API 呼び出し | $2.50/100 万回 |
| クエリ処理（10 万ベクトル以下） | $0.004/TB |

参照: [Amazon S3 Pricing](https://aws.amazon.com/s3/pricing/)

**本プロジェクトでのコスト概算**

本サンプルは約 100 レコード × 1024 次元（Titan Text Embeddings V2）= 約 0.4 MB のベクトルデータを扱う。

| 課金項目 | 計算 | 月額 |
|----------|------|------|
| ストレージ | 0.0004 GB × $0.06 | ≒ $0.00 |
| PUT 操作 | 0.0004 GB × $0.20 | ≒ $0.00 |
| クエリ | 検証用途で数百回程度 | ≒ $0.00 |
| 合計 | | ≒ **$0**（$0.01 未満） |

**他のベクトルストアとの比較（参考）**

| ベクトルストア | 月額概算（最小構成） | 備考 |
|--------------|-------------------|------|
| S3 Vectors（本プロジェクト採用） | ≒ **$0** | 完全従量課金、最小課金なし |
| OpenSearch Serverless | **$700+/月** | 最小 4 OCU（indexing 2 + search 2）× $0.24/OCU/h |
| Aurora PostgreSQL（pgvector） | $30～60/月 | db.t4g.medium のインスタンス常時稼働 |

S3 Vectors はサブセカンドのクエリレイテンシー（コールドクエリ 1 秒未満、ウォームクエリ 100ms 以下）であり、本サンプルの用途には十分である。低レイテンシー（10ms 以下）やハイブリッド検索が必要な本番ワークロードでは OpenSearch Serverless を検討する余地があるが、検証・サンプル用途では S3 Vectors が最もコスト効率が良い。

---

## 8. VPC 構成

| リソース | 数 | 課金 |
|---------|-----|------|
| VPC | 1 | 無料 |
| パブリックサブネット | 2（2 AZ） | 無料 |
| プライベートサブネット | 2（2 AZ） | 無料 |
| セキュリティグループ | 3 | 無料 |
| ルートテーブル | 2 | 無料 |
| Internet Gateway | 1 | 無料 |

VPC、サブネット、セキュリティグループ、ルートテーブル、Internet Gateway はすべて無料リソース。MSK が 2 ブローカー構成で 2 AZ 必須のため、サブネット数の削減もできない。**VPC 構成の簡素化による直接的なコスト削減効果はない。**

---

## 9. ライフサイクル管理

### 9.1 スタック削除運用の課題

| 課題 | 詳細 |
|------|------|
| MSK 作成に 20～30 分 | 気軽に再作成しにくい |
| Bedrock KB は手動作成 | スタック外のリソースは別途再作成が必要 |
| Kafka トピック再作成が必要 | `1.Setup.ipynb` を再実行する必要がある |

### 9.2 追加の運用最適化案

**AWS Budgets アラート設定**: CloudFormation テンプレートに以下を追加可能。

```yaml
CostBudget:
  Type: AWS::Budgets::Budget
  Properties:
    Budget:
      BudgetName: !Sub '${AWS::StackName}-Budget'
      BudgetLimit:
        Amount: 50
        Unit: USD
      TimeUnit: MONTHLY
      BudgetType: COST
    NotificationsWithSubscribers:
      - Notification:
          NotificationType: ACTUAL
          ComparisonOperator: GREATER_THAN
          Threshold: 80
        Subscribers:
          - SubscriptionType: EMAIL
            Address: your-email@example.com
```

**コスト配分タグの追加**: CloudFormation テンプレートの各リソースに共通タグ（`Project: BedrockStreamIngest`、`Environment: Sample`）を追加し、Cost Explorer でのフィルタリングを容易にする。

---

## 10. 代替アーキテクチャ案: CloudShell + Producer Lambda

### 10.1 背景

現在のワークフローでは SageMaker Studio のノートブック（`1.Setup.ipynb`、`2.StreamIngest.ipynb`、`3.Cleanup.ipynb`）で環境構築・テスト・クリーンアップを行っている。SageMaker Studio は VpcOnly モードでプライベートサブネットに配置されており、AWS API 呼び出しやパッケージインストール（`pip install`）のために NAT Gateway を必要とする。

しかし、各ノートブックの処理内容を精査すると、**VPC 内アクセスが必要な操作は Notebook 2 の Kafka Producer のみ**であり、それ以外はすべて AWS パブリック API 呼び出しである。

| ノートブック | 処理内容 | VPC 内アクセス |
|-------------|---------|:---:|
| 1.Setup | CloudFormation, MSK Topic API, Bedrock, Lambda の各 API 呼び出し | 不要 |
| 2.StreamIngest | confluent-kafka Producer → MSK ブローカー（Kafka プロトコル、TCP 9092） | **必要** |
| 3.Cleanup | Lambda イベントソースマッピング削除 | 不要 |

### 10.2 AWS CloudShell の特性

| 項目 | 内容 |
|------|------|
| 料金 | **無料** |
| AWS 認証 | コンソールセッションから自動取得（IAM 設定不要） |
| Python / boto3 | プリインストール済み |
| pip install | 可能（ホームディレクトリは 1 GB まで永続化） |
| ネットワーク | AWS マネージド VPC 内（ユーザーの VPC ではない） |

参照: [AWS CloudShell](https://aws.amazon.com/cloudshell/)

Notebook 1 と 3 の処理（全て AWS パブリック API）は CloudShell で **そのまま実行可能**。Notebook 2 の Kafka Producer は CloudShell からプライベートサブネットの MSK ブローカーに直接接続できないため、代替手段が必要。

### 10.3 Notebook 2 の解決策: Producer 用 Lambda 関数

CloudShell から MSK にメッセージを送信するために、**Producer 用の Lambda 関数**を追加する。

```
現状:  SageMaker Studio → (Kafka プロトコル) → MSK ブローカー
変更後: CloudShell → (Lambda Invoke API) → Producer Lambda → (Kafka プロトコル) → MSK ブローカー
```

Producer Lambda は既存の Consumer Lambda と同じ VPC・サブネット・セキュリティグループを共有するため、MSK への接続は確保される。CloudShell からは `aws lambda invoke` するだけでよい。

Producer Lambda には confluent-kafka ライブラリの Lambda レイヤーが必要になる。

### 10.4 構成変更によるコスト影響

SageMaker Studio を廃止すると、NAT Gateway の利用者は **Lambda 関数のみ**（Bedrock Agent API 呼び出し）になる。Lambda の CloudWatch Logs 送信は Lambda サービスの内部インフラで行われるため VPC ネットワーク不要。NAT Gateway を **VPC Endpoint（bedrock-agent）1 つ**に置換できる。

**削除可能なリソース**:

| リソース | 月額削減 |
|---------|---------|
| SageMaker Studio Domain + UserProfile | -$2 |
| SageMaker 用セキュリティグループ（Ingress × 3 + Egress × 3） | 構成の簡素化 |
| SageMaker 用 IAM ポリシー（8 個） | 構成の簡素化 |
| NAT Gateway（$33 → VPC Endpoint $15 に置換） | -$18 |
| Elastic IP | -$3.65 |
| **合計** | **約 -$24/月** |

VPC Endpoint のコスト: 1 エンドポイント（bedrock-agent）× 2 AZ × $0.01/h × 730h = **$14.60/月**

### 10.5 トレードオフ

| 項目 | 影響 |
|------|------|
| aws-samples の元ワークフローとの差異 | ノートブック実行から CLI スクリプト実行に変更 |
| CloudShell のセッションタイムアウト | 非アクティブ 20～30 分で切断（長時間ポーリングには不向き） |
| Producer Lambda の追加開発 | confluent-kafka レイヤーの作成 + Lambda コードの追加 |
| CloudFormation テンプレートの変更量 | SageMaker 関連リソース削除 + VPC Endpoint 追加 + Producer Lambda 追加 |

### 10.6 判定

| 方式 | 月額（ベクトルストア除く） | 難易度 |
|------|--------------------------|--------|
| 現状（SageMaker Studio + NAT Gateway） | $71 | -- |
| CloudShell + Producer Lambda + VPC Endpoint | **$47**（-$24） | 中（テンプレート改修） |
| 上記 + スタック削除運用（平日 8h × 20 日） | **$10** | 中 |

本サンプルの忠実な再現（SageMaker Studio でのノートブック実行）を重視する場合は現状構成を維持する。**コスト最適化を優先する場合は CloudShell + Producer Lambda 方式が有効**で、SageMaker Studio・NAT Gateway・Elastic IP を削除し、VPC Endpoint 1 つに置換することで月額 $24 の削減が見込める。

---

## 11. 総合コスト比較

### 11.1 現状の月額概算（24 時間稼働）

| リソース | 月額概算 | 備考 |
|---------|---------|------|
| MSK（kafka.t3.small × 2） | **$32** | ブローカー $31 + ストレージ $0.50 |
| NAT Gateway | **$33** | $32.85 + データ処理 $0.50 |
| Elastic IP | **$3.65** | パブリック IPv4 課金 |
| SageMaker Studio（JupyterLab） | **$2** | 週 2 回 × 4h 利用想定 + ストレージ |
| CloudWatch Logs（MSK） | **$0** | Free Tier 内（低トラフィック） |
| Lambda | **$0** | 検証用途で呼び出し極小 |
| Bedrock Embeddings API | **≒ $0** | 数千トークン程度 |
| VPC 関連（サブネット、SG 等） | **$0** | 無料リソース |
| ベクトルストア（S3 Vectors） | **≒ $0** | 完全従量課金、検証規模では $0.01 未満 |
| **合計** | **約 $71/月** | ベクトルストアのコストは事実上ゼロ |

### 11.2 最適化施策の一覧

| 優先度 | 施策 | 削減額/月 | 難易度 |
|--------|------|----------|--------|
| 1 | 使用しない日はスタック削除（平日 8h × 20 日稼働） | **-$54** | 低（運用変更のみ） |
| 2 | CloudShell + Producer Lambda 方式に移行（セクション 10 参照） | **-$24** | 中（テンプレート改修） |
| 3 | AWS Budgets アラートの設定 | リスク軽減 | 低 |
| 4 | JupyterLab アイドルシャットダウン設定 | **-$1～$5** | 低 |
| 5 | コスト配分タグの追加 | 可視性向上 | 低 |

S3 Vectors を採用しているため、ベクトルストアのコストは事実上ゼロであり、コスト最適化の対象外である。主なコスト要因は MSK ブローカーと NAT Gateway の固定費であり、スタック削除運用が最も効果的な削減策となる。

### 11.3 最適化後の月額概算（平日 8h × 20 日の使用想定）

| リソース | 現状（24h 稼働） | 最適化後 | 削減額 |
|---------|----------------|---------|--------|
| MSK | $32 | $6.72 | -$25.28 |
| NAT Gateway | $33 | $7.30 | -$25.70 |
| Elastic IP | $3.65 | $0.80 | -$2.85 |
| SageMaker Studio | $2 | $1 | -$1.00 |
| CloudWatch Logs | $0 | $0 | $0 |
| Lambda | $0 | $0 | $0 |
| Bedrock API | ≒ $0 | ≒ $0 | $0 |
| ベクトルストア（S3 Vectors） | ≒ $0 | ≒ $0 | $0 |
| **合計** | **$71** | **$16** | **-$55（78% 削減）** |

### 11.4 現状の構成と今後の変更のまとめ

| 項目 | 現状 | 今後の変更例 |
|------|------|--------------|
| Lambda 予約同時実行数 | **1** を採用済み | パーティション増などで必要なら 10～20 に引き上げを検討 |
| Lambda boto3 | **レイヤー**で提供（boto3 >= 1.42.46）。ランタイム pip なし | レイヤー更新時は `scripts/build-boto3-layer.sh` で再発行し、`Boto3LayerArn` を更新 |
| MSK | プロビジョンド（kafka.t3.small × 2）のまま運用 | **使わない期間はスタック削除**で固定費を削減 |
| NAT Gateway | VPC エンドポイント置換はコスト増のため現状維持 | CloudShell 方式ならVPC Endpoint 1 つに置換可能（-$18/月） |
| SageMaker Studio | 本サンプルの MSK 接続に必要 | CloudShell 方式なら廃止可能（-$2/月）、維持する場合はアイドルシャットダウン設定を追加 |
| ベクトルストア | S3 Vectors（≒ $0/月） | 検証規模では追加コストなし。本番スケールでも従量課金のため予測可能 |

現状の構成で Lambda まわりはコスト・起動時間ともに最適化済み。ベクトルストアに S3 Vectors を採用しているため、従来最大のコスト要因であったベクトルストアのコスト問題は解消されている。主なコスト要因は MSK ブローカー（$32/月）と NAT Gateway（$33/月）の固定費であり、スタック削除運用で固定費を抑える方針を推奨する。インフラ構成面では **CloudShell + Producer Lambda 方式**（セクション 10）により SageMaker Studio・NAT Gateway・Elastic IP を削除し月額 $24 の削減が見込める。
