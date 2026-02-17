# プロジェクト調査レポート: Sample Stream Ingest Amazon Bedrock Knowledge Base

## 1. プロジェクト概要

本プロジェクトは、Apache Kafka（Amazon MSK）からのストリーミングデータを Amazon Bedrock Knowledge Bases にリアルタイムで取り込むサンプル実装である。aws-samples として公開されており、MIT-0 ライセンスで提供されている。

データパイプラインの流れは以下の通り:

1. SageMaker Studio のノートブックから confluent-kafka Producer で MSK にメッセージを送信
2. Lambda 関数が MSK のイベントソースマッピング経由でメッセージを消費
3. Lambda が Bedrock Agent API (`ingest_knowledge_base_documents()`) を呼び出し、Knowledge Base にインラインテキストとしてデータを取り込む

核心的なユースケースは「ストリーミングデータをリアルタイムで RAG（Retrieval-Augmented Generation）のナレッジベースに反映する」というもので、従来のバッチ取り込み（S3 経由の同期）では実現できない即時性を提供する。

---

## 2. ディレクトリ構成

```
.
├── CLAUDE.md                     # Claude Code 用プロジェクト指示書
├── CODE_OF_CONDUCT.md            # Amazon OSS 行動規範
├── CONTRIBUTING.md               # コントリビューションガイド
├── LICENSE                       # MIT-0 ライセンス
├── README.md                     # 簡潔なプロジェクト説明
├── .gitignore                    # .DS_Store, .vscode, .cursor, .claude, build を除外
├── .python-version               # Python 3.13
├── docs/
│   └── cost-analysis-lambda-msk.md  # コスト分析ドキュメント
├── notebooks/
│   ├── 1.Setup.ipynb             # 環境構築ノートブック
│   ├── 2.StreamIngest.ipynb      # ストリーム取り込みテスト
│   ├── 3.Cleanup.ipynb           # リソースクリーンアップ
│   └── TestData.csv              # テスト用株価データ（17 銘柄）
├── scripts/
│   └── build-boto3-layer.sh      # Lambda レイヤービルドスクリプト
└── templates/
    └── bedrock-kb-stream-ingest.yml  # CloudFormation テンプレート
```

ソースコードは Lambda 関数のインラインコード（CloudFormation テンプレート内に埋め込み）と Jupyter ノートブック内のセルで構成されており、独立した Python モジュールは存在しない。

---

## 3. インフラストラクチャ詳細（CloudFormation テンプレート）

### 3.1 パラメータ

テンプレートは 3 つのパラメータを受け取る:

| パラメータ | デフォルト値 | 説明 |
|-----------|-------------|------|
| KnowledgeBaseName | BedrockStreamIngestKnowledgeBase | Bedrock KB の名前（手動作成時に使用） |
| DataSourceName | BedrockStreamIngestKBCustomDS | カスタムデータソースの名前 |
| Boto3LayerArn | （必須、デフォルトなし） | boto3 Lambda レイヤーの ARN |

Bedrock Knowledge Base 自体は CloudFormation では作成されず、AWS コンソールから手動作成する設計になっている。これは Bedrock KB の CloudFormation サポートが限定的であること（特にカスタムデータソースの設定）が理由と考えられる。

### 3.2 ネットワーク構成

VPC CIDR `10.0.0.0/16` に 4 つのサブネットを配置:

| サブネット | CIDR | AZ | 用途 |
|-----------|------|-----|------|
| PublicSubnet1 | 10.0.0.0/20 | AZ-0 | NAT Gateway 配置 |
| PublicSubnet2 | 10.0.16.0/20 | AZ-1 | （冗長性用、現状未使用） |
| PrivateSubnet1 | 10.0.128.0/20 | AZ-0 | MSK, Lambda, SageMaker |
| PrivateSubnet2 | 10.0.144.0/20 | AZ-1 | MSK, Lambda, SageMaker |

各サブネットは /20 で 4,094 ホスト分の IP アドレスを持つ。プライベートサブネットからのインターネットアクセスは NAT Gateway（PublicSubnet1 に配置）経由で提供される。

NAT Gateway が必要な理由は、Lambda が Bedrock Agent API を呼び出す際にインターネットアクセスが必要なためである（Bedrock にはパブリックエンドポイントしかない）。

### 3.3 セキュリティグループ

3 つのセキュリティグループが定義されている:

| SG | 用途 | インバウンド許可 | アウトバウンド許可 |
|----|------|----------------|------------------|
| MSKSecurityGroup | MSK クラスター | Lambda SG, SageMaker SG, 自己参照 | 全 IPv4/IPv6, Lambda SG, SageMaker SG, 自己参照 |
| LambdaSecurityGroup | Lambda 関数 | MSK SG, SageMaker SG, 自己参照 | 全 IPv4/IPv6, MSK SG, SageMaker SG, 自己参照 |
| SageMakerSecurityGroup | SageMaker Studio | Lambda SG, MSK SG, 自己参照 | 全 IPv4/IPv6, Lambda SG, MSK SG, 自己参照 |

全プロトコル（`IpProtocol: -1`）で相互通信を許可しており、検証環境としては許容範囲だが、本番環境では Kafka ポート（9092/9094）に限定すべき。

### 3.4 MSK クラスター

| 項目 | 値 |
|------|-----|
| インスタンスタイプ | kafka.t3.small |
| ブローカー数 | 2（2 AZ に 1 つずつ） |
| Kafka バージョン | 3.8.x（AWS 推奨） |
| ストレージ | EBS 5 GB/ブローカー |
| 暗号化（転送中） | TLS_PLAINTEXT（混在モード） |
| 暗号化（クラスタ内） | false |
| クライアント認証 | Unauthenticated（無認証） |
| モニタリング | DEFAULT レベル |
| ブローカーログ | CloudWatch Logs（保持 7 日） |

無認証かつ暗号化無効の構成は検証用途に限定される。本番環境では IAM 認証 + TLS が推奨される。

### 3.5 Lambda 関数

| 項目 | 値 |
|------|-----|
| ランタイム | Python 3.13 |
| タイムアウト | 900 秒 |
| 予約同時実行数 | 1 |
| VPC | プライベートサブネット 1, 2 |
| レイヤー | boto3 >= 1.42.46（パラメータで指定） |

Lambda コードは CloudFormation の `ZipFile` プロパティでインライン定義されている。処理フロー:

1. `event['records'].items()` で全トピック・パーティションを動的にイテレート
2. 各レコードの `value` を base64 デコード → UTF-8 デコード → JSON パース
3. ticker, price, timestamp を抽出
4. `datetime.fromtimestamp(timestamp, tz=timezone.utc)` でタイムスタンプを変換
5. "At {timestamp} the price of {ticker} is {price}." というテキストを生成
6. UUID を生成し、`ingest_with_backoff()` 経由で `ingest_knowledge_base_documents()` を呼び出し、インラインテキストとして取り込み

`ingest_with_backoff()` は ThrottlingException 発生時のみ exponential backoff（base 1 秒、最大 30 秒、full jitter、最大 5 回リトライ）で再試行する。正常時は sleep なしで即座に次のレコードを処理するため、17 レコードの処理は数秒で完了する。

### 3.6 SageMaker Studio

| 項目 | 値 |
|------|-----|
| ネットワークモード | VpcOnly |
| 認証 | IAM |
| デフォルト EBS | 5 GB（最大 50 GB） |
| セキュリティグループ管理 | Customer |

VpcOnly モードにより、SageMaker Studio はプライベートサブネット内に配置される。これにより MSK クラスターへの直接接続が可能になる一方、インターネットアクセス（pip install 等）に NAT Gateway が必要になる。

### 3.7 IAM ロールとポリシー

2 つの IAM ロールが定義されている:

SageMakerExecutionRole には以下のポリシーがアタッチされている:

- AWSLambda_ReadOnlyAccess（マネージドポリシー）
- AmazonSageMakerFullAccess（マネージドポリシー）
- IAM アクセス（ロール作成・削除・パス等）
- CloudWatch Metrics / Logs
- MSK アクセス（Topic Management API 含む: CreateTopic, ListTopics 等）
- CloudFormation（DescribeStacks, DescribeStackResource）
- S3 アクセス
- Bedrock アクセス（KB 操作全般）
- Lambda アクセス（イベントソースマッピング操作含む）

LambdaExecutionRole には以下のポリシーがアタッチされている:

- Bedrock アクセス（KB 操作全般）
- MSK アクセス（Read のみ + kafka-cluster 権限）
- CloudWatch Metrics / Logs
- ENI アクセス（VPC Lambda に必要）

### 3.8 CloudFormation 出力

| 出力キー | 値 |
|---------|-----|
| StackName | スタック名 |
| KnowledgeBaseName | KB 名（手動作成用） |
| DataSourceName | データソース名（手動作成用） |
| MSKClusterArn | MSK クラスター ARN |
| LambdaFunctionName | Lambda 関数名 |
| SageMakerExecutionRoleArn | SageMaker 実行ロール ARN |

---

## 4. ノートブック詳細分析

### 4.1 Notebook 1: Setup（1.Setup.ipynb）

14 セル構成。処理の流れ:

1. boto3/botocore のインポート
2. boto3 >= 1.42.46 へのアップグレード（MSK CreateTopic API に必要）
3. スタック名 `BedrockStreamIngest` とトピック名 `streamtopic` の定数定義
4. CloudFormation 出力から KBName, DSName を取得
5. CloudFormation から MSK クラスター ARN を取得
6. MSK `get_bootstrap_brokers` で接続文字列を取得
7. MSK CreateTopic API で `streamtopic` を作成（パーティション 1、レプリケーション 2）
8. MSK ListTopics API でトピック一覧を確認
9. （手動）AWS コンソールで Bedrock KB を作成する手順（マークダウンセル）
10. Bedrock `list_knowledge_bases` で KB ID を取得
11. Bedrock `list_data_sources` でデータソース ID を取得
12. Lambda 関数名を CloudFormation から取得
13. Lambda の環境変数に KBID, DSID を設定し、検証
14. MSK イベントソースマッピングを作成（StartingPosition: LATEST）し、有効化を待機（最大 3 時間、30 秒間隔）
15. `%store` で全変数を永続化

MSK Topic Management API（CreateTopic, ListTopics）は 2026 年 2 月に公開された比較的新しい API で、Kafka クライアントのインストールなしにトピックの作成・管理が可能になった。boto3 >= 1.42.46 が必要条件。

### 4.2 Notebook 2: StreamIngest（2.StreamIngest.ipynb）

5 セル構成。処理の流れ:

1. `%store -r` で前ノートブックの変数を復元
2. confluent-kafka 2.13.0 をインストール
3. ライブラリのインポート（confluent_kafka.Producer, pandas 等）
4. `put_to_topic()` 関数の定義: confluent-kafka Producer でメッセージを送信
5. TestData.csv を読み込み、各行を MSK トピックに送信

メッセージペイロードは JSON 形式:
```json
{
  "ticker": "OOOO",
  "price": "$44.50",
  "timestamp": 1739712345.678
}
```

confluent-kafka は librdkafka ベースの C 拡張ライブラリで、PyKafka（2021 年にアーカイブ済み）から移行されている。

### 4.3 Notebook 3: Cleanup（3.Cleanup.ipynb）

4 セル構成。処理の流れ:

1. `%store -r` で変数を復元
2. Lambda のイベントソースマッピング UUID を取得
3. イベントソースマッピングを削除
4. 削除完了を待機（最大 1 時間、30 秒間隔）

CloudFormation スタックの削除はこのノートブックの範囲外で、別途 AWS CLI 等で実行する必要がある。イベントソースマッピングだけを先に削除するのは、スタック削除前に Lambda への MSK トリガーを確実に切断するためと考えられる。

---

## 5. スクリプト

### 5.1 build-boto3-layer.sh

Lambda レイヤー用の boto3 パッケージをビルドし、AWS Lambda にパブリッシュするシェルスクリプト。

処理フロー:
1. `build/layer/` ディレクトリを作成（既存があれば削除）
2. `pip install --target ./python 'boto3>=1.42.46'` で python/ ディレクトリにインストール
3. `zip -r boto3-layer.zip python/` で ZIP 化
4. `aws lambda publish-layer-version` でレイヤーをパブリッシュ
5. LayerVersionArn を出力（CloudFormation パラメータに使用）

オプション引数:
- `--profile`: AWS CLI プロファイル
- `--region`: AWS リージョン
- `--attach FUNCTION_NAME`: 既存 Lambda 関数にレイヤーをアタッチ

S3 を使わず `fileb://` で直接アップロードする点が特徴的で、S3 バケットの事前作成が不要。

---

## 6. テストデータ

TestData.csv は 17 行のテスト用株価データ。

| 列 | 説明 | サンプル |
|----|------|---------|
| ticker | 架空の銘柄コード | OOOO, ZVZZT, ZNTRX 等 |
| price | 株価（ドル表記） | $44.50, "$3,413.23" 等 |

すべて架空の銘柄コード（Z で始まるものが多い。NYSE/NASDAQ のテスト用ティッカーシンボルに準拠していると推測される）。価格帯は $0.45 から $3,413.23 まで幅広い。

---

## 7. データフロー詳細

端から端までのデータフローを追跡する:

```
TestData.csv
  ↓ pandas.read_csv()
DataFrame (ticker, price)
  ↓ json.dumps({ ticker, price, timestamp })
UTF-8 バイト列
  ↓ confluent-kafka Producer.produce()
MSK Kafka トピック (streamtopic, パーティション 0)
  ↓ Lambda イベントソースマッピング (StartingPosition: LATEST)
Lambda 関数
  ↓ base64 デコード → UTF-8 デコード → JSON パース
{ticker, price, timestamp}
  ↓ テキスト整形
"At 2026-02-15 10:30:00 the price of OOOO is $44.50."
  ↓ bedrock_agent_client.ingest_knowledge_base_documents()
Bedrock Knowledge Base (インラインテキスト、UUID 付き)
  ↓ Titan Text Embeddings v2
ベクトルストア (S3 Vectors)
```

Lambda が受け取る MSK イベントの構造は `event['records']['streamtopic-0']` で、トピック名とパーティション番号がハイフンで結合されたキーでアクセスする。各レコードの `value` は base64 エンコードされている（Lambda の MSK イベントソースマッピングの仕様）。

---

## 8. 技術的な設計判断

### 8.1 Lambda インラインコード vs S3 デプロイ

Lambda コードが CloudFormation の `ZipFile` でインライン定義されている。利点は CloudFormation テンプレート 1 ファイルで完結すること、欠点はコードサイズ制限（4,096 バイト）とテストの困難さ。現状のコードは約 1,500 バイト程度なので制限内。

### 8.2 boto3 Lambda レイヤー

Lambda ランタイムのデフォルト boto3 は MSK CreateTopic API をサポートしていない（古いバージョン）。カスタムレイヤーで boto3 >= 1.42.46 を提供することで:

- ランタイムの pip install が不要（コールドスタート短縮）
- 確定的なバージョン管理が可能
- MSK Topic Management API が利用可能

### 8.3 MSK Topic Management API の採用

従来、MSK のトピック作成には Kafka Admin Client（Java/Python）が必要で、kafka-python や confluent-kafka のインストールとネットワーク設定が前提だった。2026 年 2 月に公開された MSK の Public API（CreateTopic, ListTopics 等）を採用することで、boto3 だけでトピック管理が可能になった。

### 8.4 confluent-kafka への移行

元は PyKafka を使用していたが、PyKafka は 2021 年 3 月にアーカイブされ最終リリースは 2018 年 9 月。confluent-kafka（v2.13.0）は librdkafka ベースで Kafka 3.9.x まで互換性がある。

### 8.5 予約同時実行数 = 1

1 トピック・1 パーティションの構成では、Lambda はパーティションごとにシーケンシャルにバッチを処理するため、実質的に 1 インスタンスで十分。予約同時実行数を 1 に設定することで、想定外のスケーリングを防止している。

### 8.6 Bedrock KB の手動作成

Bedrock Knowledge Base は CloudFormation テンプレートに含まれておらず、AWS コンソールから手動作成する。カスタムデータソースの CloudFormation 対応が限定的であることが理由と考えられる。ノートブック内で KB 名とデータソース名を CloudFormation 出力から取得し、コンソール操作時の値を一致させる仕組みになっている。

---

## 9. コスト分析の要約

`docs/cost-analysis-lambda-msk.md` に詳細なコスト分析がある。主要なコスト項目:

| リソース | 月額概算（24h 稼働） |
|---------|---------------------|
| MSK（kafka.t3.small x 2） | $32 |
| NAT Gateway | $33 |
| Elastic IP | $3.65 |
| SageMaker Studio | $2 |
| CloudWatch Logs | $0（Free Tier 内） |
| Lambda | $0 |
| Bedrock Embeddings API | 約 $0 |
| ベクトルストア（S3 Vectors） | 約 $0（完全従量課金、検証規模では $0.01 未満） |
| 合計 | 約 $71/月 |

ベクトルストアには Amazon S3 Vectors（2025 年 12 月 GA）を採用している。最小課金要件や OCU の概念がなく完全従量課金のため、検証規模ではコストは事実上ゼロ。参考として OpenSearch Serverless は最小 4 OCU で $700+/月、Aurora pgvector は $30～60/月かかる。

主なコスト要因は MSK ブローカー（$32/月）と NAT Gateway（$33/月）の固定費であり、使わない期間のスタック削除運用が最も効果的な削減策となる。

代替アーキテクチャとして、SageMaker Studio を CloudShell + Producer Lambda に置換する案も分析されている。これにより NAT Gateway・Elastic IP を VPC Endpoint 1 つに置換でき、月額 $24 の削減が見込める。

---

## 10. ノートブック間のデータ受け渡し

IPython の `%store` マジックを使って変数をノートブック間で永続化している。

Notebook 1 で永続化される変数:
- StackName, KafkaTopic, KBName, DSName
- LambdaFunctionName, KBId, DSId
- BootstrapBrokerString, MSKClusterArn

Notebook 2, 3 では `%store -r` で復元。この仕組みは SageMaker Studio のカーネル間で動作するが、ローカル Jupyter でも IPython のストアが利用可能。

---

## 11. セキュリティ上の考慮事項

### 11.1 検証環境として許容される点

- MSK のクライアント認証が Unauthenticated（VPC 内なので外部からのアクセスは不可）
- 暗号化が TLS_PLAINTEXT（混在モード、クラスタ内暗号化なし）
- セキュリティグループが全プロトコル許可

### 11.2 本番環境では対応が必要な点

- MSK の IAM 認証有効化
- TLS のみ（PLAINTEXT 無効化）
- セキュリティグループのポート制限（9094 for TLS）
- ~~Lambda コード内の `datetime.utcfromtimestamp()` は Python 3.12 以降で非推奨~~ → 対応済み: `datetime.fromtimestamp(timestamp, tz=timezone.utc)` に置換
- Bedrock 関連の IAM ポリシーが `Resource: '*'` で広範すぎる。KB ID やデータソース ID で絞るのが望ましい
- ~~Lambda コード内の `time.sleep(5)` はレート制限対策だが、exponential backoff の方が堅牢~~ → 対応済み: `ingest_with_backoff()` で exponential backoff + jitter を実装

---

## 12. 依存関係

### 12.1 ランタイム依存

| コンポーネント | 依存 | バージョン |
|--------------|------|-----------|
| Lambda 関数 | boto3, botocore | >= 1.42.46（レイヤー） |
| Lambda ランタイム | Python | 3.13 |
| Notebook 1 | boto3 | >= 1.42.46 |
| Notebook 2 | confluent-kafka | 2.13.0 |
| Notebook 2 | pandas | （SageMaker Studio プリインストール） |
| ビルドスクリプト | AWS CLI | v2 |
| ビルドスクリプト | pip, zip | OS 標準 |

### 12.2 AWS サービス依存

- Amazon MSK（Kafka 3.8.x）
- AWS Lambda（Python 3.13）
- Amazon Bedrock（Knowledge Base, Agent API）
- Amazon SageMaker Studio
- AWS CloudFormation
- Amazon VPC（NAT Gateway, EIP 含む）
- Amazon CloudWatch Logs
- AWS IAM

---

## 13. 制限事項と改善候補

### 13.1 現在の制限

- Bedrock KB がテンプレート外（手動作成）のため、完全な IaC ではない
- ~~Lambda コード内のトピック名 `streamtopic-0` がハードコードされている~~ → 対応済み: `event['records'].items()` で動的取得
- ~~`time.sleep(5)` による固定遅延は、レコード数が増えると処理時間が線形に増加する~~ → 対応済み: exponential backoff に置換
- テストデータの price 列がドル記号付き文字列のため、Lambda 側では数値変換せずそのまま文字列として取り込まれる
- エラーハンドリングが最小限（ThrottlingException のリトライは対応済み、それ以外は re-raise）

### 13.2 改善候補

- CloudFormation に `AWS::Bedrock::KnowledgeBase` リソースを追加（対応状況次第）
- ~~Lambda コードのトピック名をイベント構造から動的に取得~~ → 対応済み
- バッチ処理の実装（`ingest_knowledge_base_documents()` は最大 10 ドキュメントまで対応可能）
- ~~Exponential backoff の実装（`time.sleep(5)` の置換）~~ → 対応済み
- CloudFormation の Bedrock IAM ポリシーをリソース ARN で制限
- MSK の IAM 認証有効化と TLS 強制

---

## 14. 実行手順の全体フロー

```
[事前準備]
  ./scripts/build-boto3-layer.sh
  → Boto3LayerArn を取得

[CloudFormation デプロイ]
  aws cloudformation create-stack ... --parameters Boto3LayerArn=...
  → 20-30 分待機（MSK クラスター作成）

[SageMaker Studio でノートブック実行]
  1.Setup.ipynb
    → boto3 アップグレード
    → MSK トピック作成（CreateTopic API）
    → AWS コンソールで Bedrock KB 手動作成
    → Lambda 環境変数設定
    → MSK イベントソースマッピング作成

  2.StreamIngest.ipynb
    → confluent-kafka インストール
    → TestData.csv の 17 レコードを MSK に送信
    → Lambda が自動起動 → Bedrock KB にインジェスト

  3.Cleanup.ipynb
    → イベントソースマッピング削除

[スタック削除]
  aws cloudformation delete-stack --stack-name BedrockStreamIngest
  → 20-30 分待機
```

---

## 15. まとめ

本プロジェクトは、Amazon Bedrock Knowledge Bases の `ingest_knowledge_base_documents()` API を使ったストリーミングデータのリアルタイム取り込みを実証するサンプル実装である。

技術的な特徴:
- MSK + Lambda のイベント駆動アーキテクチャでリアルタイムパイプラインを構築
- MSK Topic Management API（2026 年 2 月公開）の採用により Kafka クライアント不要でトピック管理が可能
- Lambda レイヤーによる boto3 バージョン管理でコールドスタートを最小化
- confluent-kafka による堅牢な Kafka Producer 実装

アーキテクチャ上の特性:
- CloudFormation 1 テンプレートでインフラの大部分を管理（Bedrock KB を除く）
- SageMaker Studio の VpcOnly モードで MSK への直接接続を実現
- 検証用途に特化した構成（無認証 MSK、広範な IAM ポリシー、全プロトコル許可の SG）
- コスト最適化の詳細分析と代替アーキテクチャの検討が文書化されている

本サンプルは「動くデモ」として完成度が高く、ストリーミング → RAG のパイプラインを理解するための教材として有用である。本番環境への適用にはセキュリティ強化（MSK 認証、TLS、IAM ポリシーの絞り込み）と運用面の改善（エラーハンドリング、バッチ処理、モニタリング）が必要になる。
