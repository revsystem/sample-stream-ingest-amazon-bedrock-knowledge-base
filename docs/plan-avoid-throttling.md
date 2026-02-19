# 実装計画: Bedrock API スロットリング回避

対象ファイル: `templates/bedrock-kb-stream-ingest.yml`（Lambda インラインコード、L844〜L946）

---

## 1. 現状の問題

### 1.1 発生している事象

Lambda 関数が MSK から受信したレコードを処理する際、Bedrock `ingest_knowledge_base_documents()` API に対して 1 件ずつ高速にリクエストを送信するため、ThrottlingException（Too Many Requests, HTTP 429）が発生する。

### 1.2 現在の Lambda コードの処理フロー

`templates/bedrock-kb-stream-ingest.yml` の Lambda 関数（L844-L946）は以下のように動作する。

1. `event['records']` から全トピック-パーティションのレコードを取得
2. レコードごとに 1 件ずつ `ingest_with_backoff()` を呼び出す
3. 各呼び出しでは 1 ドキュメントだけを含む API リクエストを送信
4. リクエスト間のディレイは一切なし

MSK Event Source Mapping のデフォルト BatchSize は 100 のため、1 回の Lambda 呼び出しで最大 100 レコードが届き、100 回の連続 API 呼び出しが発生しうる。

### 1.3 既存のスロットリング対策

`ingest_with_backoff()` 関数（L864-L880）にリアクティブなリトライ機構がある。

- 最大リトライ回数: 5
- 指数バックオフ: `min(1.0 * 2^attempt + random(0,1), 30.0)` 秒
- `ThrottlingException` のみ捕捉

この機構は ThrottlingException が発生した後にリトライするリアクティブな対策であり、そもそもスロットリングを発生させないプロアクティブな対策が欠けている。

---

## 2. Bedrock API のレートリミット

AWS 公式ドキュメントに基づくレートリミットは以下のとおり。

| API | TPS 上限 | 1 リクエストあたりの最大ドキュメント数 | ペイロードサイズ上限 | 調整可否 |
|-----|----------|--------------------------------------|---------------------|---------|
| IngestKnowledgeBaseDocuments | 5 | 10 | 6 MB | 不可（Fixed） |

追加の制約:

- IngestKnowledgeBaseDocuments と DeleteKnowledgeBaseDocuments の同時実行リクエスト合計は 10 まで（アカウント・リージョン単位）
- Lambda の ReservedConcurrentExecutions=1 のため、同時実行数の制約は本プロジェクトでは問題にならない

出典:

- [Amazon Bedrock endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/bedrock.html)
- [IngestKnowledgeBaseDocuments API Reference](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_IngestKnowledgeBaseDocuments.html)

---

## 3. 参照プロジェクトの実績データ

別プロジェクト（`docs/plan-avoid-throttling-tmp.md`, `templates/bedrock-kb-stream-ingest-tmp.yml`）で同様のスロットリング対策を実施済み。そのチューニング結果を以下に示す。

| BATCH_DELAY | 実効 RPS | 結果 |
|-------------|----------|------|
| 0.5 秒 | 2 TPS | 多数の TooManyRequests が発生 |
| 1.0 秒 | 1 TPS | 頻度低下するが依然発生 |
| 2.0 秒 | 0.5 TPS | スロットリング完全解消 |

この結果から、ドキュメント上の 5 TPS 制限よりも実効的な上限はかなり低いことがわかる。API 側の内部処理（ベクトル埋め込み生成等）がボトルネックになっていると推測される。

参照プロジェクトの設計判断で本プロジェクトに適用するもの:

- `BATCH_SIZE = 10`（API の 1 リクエストあたり最大ドキュメント数に合わせる）
- `BATCH_DELAY` を環境変数化し、デプロイなしにチューニング可能にする
- デフォルト値は実績に基づき 2.0 秒
- 不要な import の削除（`logging`, `from botocore.exceptions import ClientError`）は `feature/improve-lambda-code` ブランチで実施し、本ブランチにマージ後の前提とする

---

## 4. 改善戦略

2 つの戦略を組み合わせる。

### 戦略 A: バッチ処理（API 呼び出し回数の削減）

1 回の呼び出しで最大 10 ドキュメントを処理できるため、現在 1 件ずつ送信しているものを 10 件ずつまとめることで API 呼び出し回数を約 1/10 に削減する。

### 戦略 B: バッチ間ディレイ（プロアクティブなレート制御）

バッチ間に適切なディレイを挿入してスロットリングを予防する。環境変数 `BATCH_DELAY` で調整可能にすることで、デプロイなしにチューニングできるようにする。

- デフォルト: 2.0 秒（参照プロジェクトの実績に基づく）
- 環境変数 `BATCH_DELAY` でオーバーライド可能

### 効果の見積もり

100 レコードが 1 回の Lambda 呼び出しで届いた場合の比較:

| 指標 | 変更前 | 変更後 |
|------|--------|--------|
| API 呼び出し回数 | 100 回 | 10 回 |
| 想定スループット | 制御なし → 即座にスロットリング | 0.5 TPS（2.0 秒間隔） |
| 処理時間（正常時） | スロットリング + リトライで不安定 | 10 × 2.0 = 約 20 秒 + API 応答時間 |
| ThrottlingException の発生頻度 | 高頻度 | ほぼゼロ（リトライ機構がフォールバック） |

17 レコード（TestData.csv）の場合:

| 指標 | 変更前 | 変更後 |
|------|--------|--------|
| API 呼び出し回数 | 17 回 | 2 回 |
| 処理時間（正常時） | 数秒 + スロットリング遅延 | 約 2.0 秒（1 間隔） |

---

## 5. CloudFormation ZipFile サイズの制約

Lambda インラインコードは CloudFormation の `ZipFile` プロパティで定義されており、上限は 4,096 バイト。

現在のコードサイズ: 3,788 バイト（残り 308 バイト）

バッチ化の実装にはコード追加が必要だが、以下のバイト削減策で相殺する。

### 削減策 1: 冗長な print 文の集約

1 レコードあたり 7 行の print を 1 行に集約する。`payload_string` には ticker、price、timestamp がすべて含まれているため、個別の出力は冗長。

```python
# 変更前（7 行、約 226 バイト）
print('## RECORD')
print('Decoded event main', event_payload)
print('## RECORD UUID', str(myuuid))
print('## TICKER: ', ticker)
print('## PRICE: ', price)
print('## TIMESTAMP: ', payload_ts)
print('## PAYLOAD STRING: ', payload_string)

# 変更後（1 行、約 46 バイト）
print(f'## DOC {myuuid}: {payload_string}')
```

### 削減策 2: 未使用 import の削除（feature/improve-lambda-code ブランチで実施）

以下の削除は `feature/improve-lambda-code` ブランチで行い、本ブランチにマージ後の前提とする。

```python
# 削除: 使用箇所なし（コードは botocore.exceptions.ClientError を直接参照）
from botocore.exceptions import ClientError

# 削除: decode_payload 内の logging.info() を print に置換
import logging
```

### 削減策 3: 冗長な冒頭ログの整理

```python
# 変更前（5 行）
print('## ENVIRONMENT VARIABLES')
print(os.environ['AWS_LAMBDA_LOG_GROUP_NAME'])
print(os.environ['AWS_LAMBDA_LOG_STREAM_NAME'])
print(kb_id)
print(ds_id)

# 変更後（1 行）
print(f'KBID: {kb_id}, DSID: {ds_id}, BATCH_DELAY: {BATCH_DELAY}')
```

変更後のサイズ見積もり: 約 3,600〜3,800 バイト（4,096 バイト以内）。実装後に正確な計測を行う。

---

## 6. 実装計画

### 6.1 対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `templates/bedrock-kb-stream-ingest.yml` | Lambda 関数コード改修 |
| `CLAUDE.md` | Lambda 関数の説明と環境変数セクションの更新 |

### 6.2 Lambda 関数コードの変更

#### 6.2.1 import の整理（feature/improve-lambda-code ブランチで実施）

以下は `feature/improve-lambda-code` ブランチで実施済みの前提。本ブランチでは変更しない。

```python
# 削除対象（feature/improve-lambda-code ブランチ）
import logging
from botocore.exceptions import ClientError
```

#### 6.2.2 定数の追加

```python
BATCH_SIZE = 10
BATCH_DELAY = float(os.environ.get('BATCH_DELAY', '2.0'))
```

- `BATCH_SIZE` は API の上限（10 ドキュメント/リクエスト）に合わせる
- `BATCH_DELAY` は環境変数から取得し、デフォルト 2.0 秒（参照プロジェクトの実績値）

#### 6.2.3 ingest_with_backoff() のシグネチャ維持

本プロジェクトは ingest のみのため、参照プロジェクトの `_retry_on_throttle(func)` パターンは採用せず、既存の `ingest_with_backoff(client, kb_id, ds_id, documents)` シグネチャを維持する。変更は ThrottlingException 判定のみ（機能的変更なし）。

#### 6.2.4 lambda_handler の処理フロー変更

```
変更前:
  for each topic_partition:
      for each record:
          build 1 document → ingest_with_backoff(1 doc) → 次のレコードへ

変更後:
  Phase 1 - 収集:
      for each topic_partition:
          for each record:
              all_documents リストに追加

  Phase 2 - バッチ ingest:
      for each batch of 10 in all_documents:
          ingest_with_backoff(batch)
          最終バッチ以外は time.sleep(BATCH_DELAY)
```

#### 6.2.5 decode_payload の簡素化（feature/improve-lambda-code ブランチで実施）

`logging.info()` 行の削除は `feature/improve-lambda-code` ブランチで実施。本ブランチでは変更しない。

#### 6.2.6 Lambda の Description 更新

```yaml
Description: "Kafka Consumer Lambda Function - v3 batch processing with rate limiting"
```

### 6.3 変更後の Lambda 関数コード（全体像）

```python
import os
import json
import base64
import random
import time
import uuid
from datetime import datetime, timezone

import boto3
import botocore

bedrock_agent_client = boto3.client('bedrock-agent', region_name='us-east-1')

MAX_RETRIES = 5
BASE_DELAY = 1.0
MAX_DELAY = 30.0
BATCH_SIZE = 10
BATCH_DELAY = float(os.environ.get('BATCH_DELAY', '2.0'))

def ingest_with_backoff(client, kb_id, ds_id, documents):
    for attempt in range(MAX_RETRIES):
        try:
            response = client.ingest_knowledge_base_documents(
                knowledgeBaseId=kb_id,
                dataSourceId=ds_id,
                documents=documents
            )
            return response
        except botocore.exceptions.ClientError as error:
            error_code = error.response['Error']['Code']
            if error_code == 'ThrottlingException' and attempt < MAX_RETRIES - 1:
                delay = min(BASE_DELAY * (2 ** attempt) + random.uniform(0, 1), MAX_DELAY)
                print(f'ThrottlingException, retrying in {delay:.1f}s (attempt {attempt + 1}/{MAX_RETRIES})')
                time.sleep(delay)
            else:
                raise

def lambda_handler(event, context):
    print(f'boto3 version: {boto3.__version__}')
    print(f'botocore version: {botocore.__version__}')
    kb_id = os.environ['KBID']
    ds_id = os.environ['DSID']
    print(f'KBID: {kb_id}, DSID: {ds_id}, BATCH_DELAY: {BATCH_DELAY}')

    all_documents = []
    for topic_partition, records in event['records'].items():
        print(f'## PROCESSING: {topic_partition}')
        for rec in records:
            event_payload = decode_payload(rec['value'])
            ticker = event_payload['ticker']
            price = event_payload['price']
            timestamp = event_payload['timestamp']
            myuuid = uuid.uuid4()
            payload_ts = datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            payload_string = "At " + payload_ts + " the price of " + ticker + " is " + str(price) + "."
            print(f'## DOC {myuuid}: {payload_string}')
            all_documents.append({
                'content': {
                    'custom': {
                        'customDocumentIdentifier': {
                            'id': str(myuuid)
                        },
                        'inlineContent': {
                            'textContent': {
                                'data': payload_string
                            },
                            'type': 'TEXT'
                        },
                        'sourceType': 'IN_LINE'
                    },
                    'dataSourceType': 'CUSTOM'
                }
            })

    print(f'## TOTAL DOCUMENTS: {len(all_documents)}')

    for i in range(0, len(all_documents), BATCH_SIZE):
        batch = all_documents[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1
        total_batches = (len(all_documents) + BATCH_SIZE - 1) // BATCH_SIZE
        print(f'## INGESTING BATCH {batch_num}/{total_batches} ({len(batch)} docs)')
        response = ingest_with_backoff(bedrock_agent_client, kb_id, ds_id, batch)
        print(f'## BATCH RESPONSE: {response}')
        if i + BATCH_SIZE < len(all_documents):
            time.sleep(BATCH_DELAY)

    return {'statusCode': 200, 'body': json.dumps('Success from Lambda!')}

def decode_payload(event_data):
    agg_data_bytes = base64.b64decode(event_data)
    decoded_data = agg_data_bytes.decode(encoding="utf-8")
    event_payload = json.loads(decoded_data)
    return event_payload
```

### 6.4 CLAUDE.md の更新

Lambda Function Code セクションに以下を追加:

- バッチ処理の説明（10 ドキュメント/API コール）
- バッチ間ディレイの説明（`BATCH_DELAY` 環境変数、デフォルト 2.0 秒）
- IngestKnowledgeBaseDocuments API の制約（10 ドキュメント/リクエスト、5 RPS）

Required Environment Variables セクションに `BATCH_DELAY`（optional、デフォルト 2.0）を追加。

---

## 7. BATCH_DELAY のチューニング

デプロイ後にスロットリングの発生状況に応じて、Lambda の環境変数でディレイを調整できる。

```bash
aws lambda update-function-configuration \
  --function-name BedrockStreamIngestKafkaConsumerLambdaFunction \
  --environment "Variables={KBID=<KB_ID>,DSID=<DS_ID>,BATCH_DELAY=3.0}"
```

| BATCH_DELAY | 実効スループット | 用途 |
|-------------|-----------------|------|
| 1.0 秒 | 10 docs/sec | 高スループットが必要な場合（スロットリングリスクあり） |
| 2.0 秒 | 5 docs/sec | デフォルト（参照プロジェクトで検証済み） |
| 3.0 秒 | 3.3 docs/sec | 安全マージンを広げたい場合 |

---

## 8. リスクと緩和策

| リスク | 影響 | 緩和策 |
|--------|------|--------|
| ZipFile サイズ超過 | Lambda デプロイ失敗 | 実装後にバイト数を計測。超過する場合は decode_payload の print を削減 |
| バッチ内の 1 件が不正データの場合 | API エラー | API は各ドキュメントの成否をレスポンスで返すため、部分的な成功が可能。サンプルプロジェクトでは個別のエラーハンドリングは省略 |
| BATCH_DELAY=2.0 でもスロットリング発生 | リトライ増加 | 環境変数で BATCH_DELAY を増やして対応。指数バックオフが第二防衛線 |

---

## 9. 検証方法

1. 変更後のコードサイズが 4,096 バイト以内であることを計測で確認
2. CloudFormation スタックを更新して Lambda 関数をデプロイ
3. `notebooks/2.StreamIngest.ipynb` でテストデータ（17 レコード）を MSK に送信
4. CloudWatch Logs で以下を確認:
   - `BATCH_DELAY: 2.0` がログに出力されること
   - `## TOTAL DOCUMENTS: 17` が出力されること
   - `## INGESTING BATCH 1/2 (10 docs)` と `## INGESTING BATCH 2/2 (7 docs)` が出力されること
   - ThrottlingException のリトライログが発生しないこと
   - 正常終了（statusCode: 200）すること

---

## 10. TODO リスト

全フェーズと個別タスクの一覧。チェックボックスで進捗を追跡する。

### Phase 1: 事前準備

- [x] 1-1. `feat/batch-processing-rate-limiting` ブランチにいることを確認
- [x] 1-2. git の作業ツリーがクリーンであることを確認（untracked: plan-avoid-throttling.md, tmp files のみ）
- [x] 1-3. 現在の ZipFile コードサイズを計測し、ベースラインとして記録（現状: 3,788 バイト、残り 308 バイト）

### Phase 2: 前提作業（`feature/improve-lambda-code` ブランチ）

- [x] 2-1. `feature/improve-lambda-code` ブランチに切り替え
- [x] 2-2. `import logging` を削除（L849）
- [x] 2-3. `from botocore.exceptions import ClientError` を削除（L856）
- [x] 2-4. `decode_payload` 内の `logging.info(f'Decoded data from kafka topic: {event_payload}')` 行を削除（L945）
- [x] 2-5. 変更をコミット → 34b4da6
- [x] 2-6. `feat/batch-processing-rate-limiting` ブランチに切り替え
- [x] 2-7. `feature/improve-lambda-code` の変更を本ブランチにマージ（fast-forward）
- [x] 2-8. マージ後の ZipFile コードサイズを計測 → 3,661 バイト（127 バイト削減、残り 435 バイト）

### Phase 3: コード変更（`templates/bedrock-kb-stream-ingest.yml`）

- [x] 3-1. 定数 `BATCH_SIZE = 10` を `MAX_DELAY = 30.0` の後に追加
- [x] 3-2. 定数 `BATCH_DELAY = float(os.environ.get('BATCH_DELAY', '2.0'))` を `BATCH_SIZE` の後に追加
- [x] 3-3. `lambda_handler` 冒頭のログ出力を整理:
  - [x] 3-3a. `print('## ENVIRONMENT VARIABLES')` を削除
  - [x] 3-3b. `print(os.environ['AWS_LAMBDA_LOG_GROUP_NAME'])` を削除
  - [x] 3-3c. `print(os.environ['AWS_LAMBDA_LOG_STREAM_NAME'])` を削除
  - [x] 3-3d. `print(kb_id)` と `print(ds_id)` を `print(f'KBID: {kb_id}, DSID: {ds_id}, BATCH_DELAY: {BATCH_DELAY}')` に置換
  - [x] 3-3e. `print('## EVENT')` と `print(event)` を削除
- [x] 3-4. `lambda_handler` を 2 フェーズ構成に書き換え:
  - [x] 3-4a. `all_documents = []` リストを初期化
  - [x] 3-4b. レコードごとの冗長な print 文を 1 行に集約 → `print(f'## DOC {myuuid}: {payload_string}')`
  - [x] 3-4c. ドキュメント構築を `all_documents.append(...)` に変更
  - [x] 3-4d. `ingest_with_backoff()` の呼び出しをレコードループ内から削除
  - [x] 3-4e. `print(f'## TOTAL DOCUMENTS: {len(all_documents)}')` を追加
  - [x] 3-4f. バッチ処理ループを追加
  - [x] 3-4g. バッチスライス実装
  - [x] 3-4h. バッチ番号計算と進捗ログ実装
  - [x] 3-4i. バッチ単位での `ingest_with_backoff()` 呼び出し実装
  - [x] 3-4j. バッチレスポンスログ実装
  - [x] 3-4k. 最終バッチ以外で `time.sleep(BATCH_DELAY)` を挿入
- [x] 3-5. Lambda Description を v3 に更新

### Phase 4: コード検証（ローカル）

- [x] 4-1. 変更後の ZipFile コードサイズが 4,096 バイト以内であることを計測 → 3,562 バイト（残り 534 バイト）
- [x] 4-2. サイズ超過の場合: `decode_payload` 内の print 文削減、または `print(f'## EVENT records: {len(event["records"])}')` のような軽量ログに切り替えて再計測 → スキップ（サイズ超過なし）
- [x] 4-3. `git diff` で変更箇所が意図どおりであることを確認
- [x] 4-4. セクション 6.3「変更後の Lambda 関数コード（全体像）」と差分を突き合わせ、漏れがないことを確認 → 完全一致
- [x] 4-5. Python インデントが YAML `|` ブロック内で正しいことを目視確認（12 スペースの YAML インデント + 12 スペースの Python インデント）

### Phase 5: ドキュメント更新

- [x] 5-1. `CLAUDE.md` の「Lambda Function Code」セクション（L156-L168）を更新:
  - [x] 5-1a. `Calls ingest_knowledge_base_documents()` の記述にバッチ処理の説明を追加（10 ドキュメント/API コール）
  - [x] 5-1b. バッチ間ディレイの説明を追加（`BATCH_DELAY` 環境変数、デフォルト 2.0 秒）
  - [x] 5-1c. IngestKnowledgeBaseDocuments API の制約を記載（10 ドキュメント/リクエスト、5 RPS）
- [x] 5-2. `CLAUDE.md` の「Required Environment Variables (Lambda)」セクション（L170-L175）に `BATCH_DELAY` を追加:
  - `BATCH_DELAY`（optional）: バッチ間ディレイ秒数。デフォルト 2.0。環境変数で調整可能

### Phase 6: デプロイと動作検証

- [ ] 6-1. CloudFormation スタックを更新

```bash
aws cloudformation update-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters ParameterKey=Boto3LayerArn,ParameterValue=<既存の ARN> \
  --capabilities CAPABILITY_NAMED_IAM
```

- [ ] 6-2. スタック更新の完了を待機

```bash
aws cloudformation wait stack-update-complete --stack-name BedrockStreamIngest
```

- [ ] 6-3. Lambda 関数のコードが正しく更新されたことを確認（AWS コンソールまたは `aws lambda get-function`）
- [ ] 6-4. `notebooks/2.StreamIngest.ipynb` を実行して TestData.csv の 17 レコードを MSK に送信
- [ ] 6-5. CloudWatch Logs で Lambda の実行ログを確認:
  - [ ] 6-5a. `BATCH_DELAY: 2.0` がログに出力されていること
  - [ ] 6-5b. `## TOTAL DOCUMENTS: 17` が出力されていること
  - [ ] 6-5c. `## INGESTING BATCH 1/2 (10 docs)` が出力されていること
  - [ ] 6-5d. `## INGESTING BATCH 2/2 (7 docs)` が出力されていること
  - [ ] 6-5e. ThrottlingException のリトライログが出力されていないこと
  - [ ] 6-5f. 正常終了（statusCode: 200）していること
- [ ] 6-6. Bedrock Knowledge Base に 17 件のドキュメントが取り込まれていることを確認

### Phase 7: チューニング（必要に応じて）

- [ ] 7-1. Bedrock マネジメントコンソールで TooManyRequests エラーの有無を確認
- [ ] 7-2. スロットリングが発生している場合: Lambda 環境変数 `BATCH_DELAY` を増やして対応

```bash
aws lambda update-function-configuration \
  --function-name BedrockStreamIngestKafkaConsumerLambdaFunction \
  --environment "Variables={KBID=<KB_ID>,DSID=<DS_ID>,BATCH_DELAY=3.0}"
```

- [ ] 7-3. チューニング結果を本ドキュメントに追記（BATCH_DELAY 値と結果の対応表）

### Phase 8: 完了確認

- [ ] 8-1. 変更前後のスロットリング発生状況を比較し、改善を確認
- [ ] 8-2. `docs/plan-avoid-throttling.md` の TODO リストを完了済みに更新
- [ ] 8-3. 変更内容をコミット
