# 実装計画: Lambda コードの 3 つの改善

対象ファイル: `templates/bedrock-kb-stream-ingest.yml`（843〜932 行目、Lambda インラインコード）

---

## 変更 1: `datetime.utcfromtimestamp()` の置換

### 背景

`datetime.utcfromtimestamp()` は Python 3.12 で非推奨（DeprecationWarning）となり、将来のバージョンで削除される予定。naive な datetime オブジェクト（タイムゾーン情報なし）を返すため、タイムゾーンの取り扱いで混乱を招きやすい。

参照: <https://docs.python.org/3.13/library/datetime.html#datetime.datetime.utcfromtimestamp>

### 現在のコード（886 行目）

```python
payload_ts = datetime.utcfromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')
```

### 変更後のコード

```python
payload_ts = datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
```

### 必要な import の変更（851 行目）

```python
# 変更前
from datetime import datetime

# 変更後
from datetime import datetime, timezone
```

### 動作への影響

出力フォーマットは同一（`%Y-%m-%d %H:%M:%S`）。`fromtimestamp` に `tz=timezone.utc` を渡すことで aware な datetime オブジェクトが返されるが、`strftime` の出力文字列には差異がない。Bedrock KB に取り込まれるペイロード文字列は変わらない。

---

## 変更 2: `time.sleep(5)` を exponential backoff に置換

### 背景

現在は各レコードの `ingest_knowledge_base_documents()` 呼び出し前に一律 5 秒の sleep を入れている。API スロットリングへの簡易対策だが、以下の問題がある:

- スロットリングが発生しない場合でも無条件に待機するため、17 レコードで約 85 秒の無駄な遅延が生じる
- 実際にスロットリングが発生した場合、5 秒では不十分な可能性がある
- レコード数に比例して処理時間が線形に増加する

### 設計方針

sleep を API 呼び出しの前ではなく、`ClientError`（ThrottlingException）発生時のリトライロジックに移動する。正常時は sleep なしで処理し、スロットリングが発生した場合のみ exponential backoff でリトライする。

`ingest_knowledge_base_documents()` API のスロットリング例外は `ThrottlingException`（HTTP 429）。

### 変更後のコード（概要）

```python
import random

MAX_RETRIES = 5
BASE_DELAY = 1.0
MAX_DELAY = 30.0

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
```

### リトライパラメータの根拠

| パラメータ | 値 | 根拠 |
|-----------|-----|------|
| MAX_RETRIES | 5 | AWS SDK のデフォルトリトライ回数に合わせる |
| BASE_DELAY | 1.0 秒 | 初回リトライは軽く。元の 5 秒よりも短い |
| MAX_DELAY | 30.0 秒 | Lambda タイムアウト 900 秒に対して十分な余裕を持つ |
| ジッタ | 0〜1 秒のランダム加算 | 複数 Lambda インスタンスの同時リトライ衝突を回避（full jitter） |

リトライ間隔の推移: 1〜2 秒 → 2〜3 秒 → 4〜5 秒 → 8〜9 秒 → 16〜17 秒（最大 5 回で合計約 31〜36 秒）。

### `time.sleep(5)` の削除

890 行目の `time.sleep(5)` を削除し、上記の `ingest_with_backoff()` 関数を呼び出すように変更する。正常時は sleep なしで即座に次のレコードを処理するため、17 レコードの処理時間は約 85 秒から数秒に短縮される。

### CloudFormation ZipFile サイズへの影響

`ingest_with_backoff()` 関数の追加で約 500 バイト増加。現在約 1,500 バイト → 約 2,000 バイト。ZipFile の上限 4,096 バイトに収まる。`random` モジュールの import を 1 行追加する。

---

## 変更 3: トピック名の動的取得

### 背景

現在は `event['records']['streamtopic-0']` でトピック名とパーティション番号がハードコードされている。MSK Lambda イベントの構造は以下の通り:

```json
{
  "eventSource": "aws:kafka",
  "records": {
    "streamtopic-0": [
      {
        "topic": "streamtopic",
        "partition": 0,
        "offset": 15,
        "timestamp": 1545084650987,
        "value": "base64encodedvalue..."
      }
    ]
  }
}
```

`event['records']` の各キーは `{topic}-{partition}` 形式で、複数トピック・複数パーティションの場合は複数のキーが存在する。各レコード内にも `topic` フィールドがある。

### 変更後のコード（872 行目付近）

```python
# 変更前
records = event['records']['streamtopic-0']

# 変更後
for topic_partition, records in event['records'].items():
    for rec in records:
        # 既存の処理...
```

`event['records']` を `items()` でイテレートすることで、トピック名やパーティション番号に関係なくすべてのレコードを処理する。

### インデントの変更

既存の `for rec in records:` ループの本体を `for topic_partition, records in event['records'].items():` の内側にネストする必要がある。CloudFormation YAML 内のインラインコードなので、インデントの追加は YAML の構造に影響しない（`|` ブロックスカラー内）。

### 動作への影響

- 単一トピック・単一パーティションの現構成では動作は変わらない
- 将来的にパーティション数を増やした場合（例: `streamtopic-0`, `streamtopic-1`）、すべてのパーティションのレコードを処理できる
- 複数トピックのイベントソースマッピングを追加した場合も対応可能

---

## 変更の全体像

3 つの変更はすべて `templates/bedrock-kb-stream-ingest.yml` の Lambda インラインコード（843〜932 行目）に対するもので、他のファイルへの変更は不要。

### 変更後の Lambda コード全体

```python
import os
import json
import base64
import logging
import random
import time
import uuid
from datetime import datetime, timezone

import boto3
import botocore
from botocore.exceptions import ClientError

bedrock_agent_client = boto3.client('bedrock-agent')

MAX_RETRIES = 5
BASE_DELAY = 1.0
MAX_DELAY = 30.0

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
    print('## ENVIRONMENT VARIABLES')
    print(os.environ['AWS_LAMBDA_LOG_GROUP_NAME'])
    print(os.environ['AWS_LAMBDA_LOG_STREAM_NAME'])
    kb_id = os.environ['KBID']
    print(kb_id)
    ds_id = os.environ['DSID']
    print(ds_id)
    print('## EVENT')
    print(event)

    for topic_partition, records in event['records'].items():
        print(f'## PROCESSING: {topic_partition}')
        for rec in records:
            print('## RECORD')
            event_payload = decode_payload(rec['value'])
            print('Decoded event main', event_payload)
            ticker = event_payload['ticker']
            price = event_payload['price']
            timestamp = event_payload['timestamp']
            myuuid = uuid.uuid4()
            print('## RECORD UUID', str(myuuid))
            print('## TICKER: ', ticker)
            print('## PRICE: ', price)
            payload_ts = datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            print('## TIMESTAMP: ', payload_ts)
            payload_string = "At " + payload_ts + " the price of " + ticker + " is " + str(price) + "."
            print('## PAYLOAD STRING: ', payload_string)
            documents = [
                {
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
                }
            ]
            response = ingest_with_backoff(bedrock_agent_client, kb_id, ds_id, documents)
            print('## INGEST KNOWLEDGE BASE DOCUMENTS RESPONSE: ', response)

    return {
        'statusCode': 200,
        'body': json.dumps('Success from Lambda!')
    }

def decode_payload(event_data):
    print('Received event', event_data)
    agg_data_bytes = base64.b64decode(event_data)
    decoded_data = agg_data_bytes.decode(encoding="utf-8")
    event_payload = json.loads(decoded_data)
    print('Decoded event', event_payload)
    logging.info(f'Decoded data from kafka topic: {event_payload}')
    return event_payload
```

### コードサイズ見積もり

変更後のコードは約 2,800 バイト。CloudFormation ZipFile の上限 4,096 バイト以内。

---

## テスト方針

### 変更 1（datetime）の検証

CloudWatch Logs でペイロード文字列の出力を確認し、タイムスタンプのフォーマットが `YYYY-MM-DD HH:MM:SS` であることを検証。

### 変更 2（exponential backoff）の検証

- 正常系: スロットリングが発生しない場合、sleep なしで処理が完了することを CloudWatch Logs の処理時間から確認（17 レコードが数秒で完了）
- 異常系: Bedrock API の同時呼び出し等でスロットリングを意図的に発生させ、リトライログ（`ThrottlingException, retrying in ...`）が出力されることを確認

### 変更 3（動的トピック名）の検証

既存の `streamtopic` で動作確認。`event['records']` のキーが `streamtopic-0` であることを CloudWatch Logs で確認し、レコードが正常に処理されることを検証。

---

## 実装手順

1. `templates/bedrock-kb-stream-ingest.yml` の Lambda インラインコード（843〜932 行目）を上記の変更後コードに置換
2. CloudFormation スタックを更新（`aws cloudformation update-stack`）
3. `2.StreamIngest.ipynb` でテストデータを送信し、CloudWatch Logs で動作を確認
4. 処理時間の短縮（約 85 秒 → 数秒）を確認

---

## リスクと緩和策

| リスク | 影響 | 緩和策 |
|--------|------|--------|
| ZipFile サイズ超過 | Lambda デプロイ失敗 | 事前にバイト数を計測。超過する場合は print 文を削減 |
| exponential backoff で全リトライ失敗 | 一部レコードの取り込み漏れ | MAX_RETRIES=5 で十分なリトライ回数。失敗時は例外が raise され CloudWatch Logs に記録される |
| 動的トピック名で予期しないキー形式 | レコード処理の失敗 | MSK イベントの `records` キーは AWS が `{topic}-{partition}` 形式で保証。`items()` はキー形式に依存しない |

---

## TODO リスト

### Phase 1: 事前準備

- [x] 1-1. 現在の Lambda インラインコード（`templates/bedrock-kb-stream-ingest.yml` 843〜932 行目）のバックアップとして git の現状をコミット済みであることを確認
- [x] 1-2. 変更後コードのバイト数を計測し、ZipFile 上限 4,096 バイト以内であることを検証 → 3,764 バイト
- [ ] 1-3. CloudFormation スタック `BedrockStreamIngest` が正常稼働中であることを確認 → スタック未稼働のためスキップ

### Phase 2: コード変更（`templates/bedrock-kb-stream-ingest.yml`）

- [x] 2-1. import 文の変更: `from datetime import datetime` → `from datetime import datetime, timezone`
- [x] 2-2. import 文の追加: `import random`
- [x] 2-3. `ingest_with_backoff()` 関数の追加（`lambda_handler` の前に配置）
  - [x] 2-3a. リトライ定数の定義（MAX_RETRIES=5, BASE_DELAY=1.0, MAX_DELAY=30.0）
  - [x] 2-3b. ThrottlingException 判定とリトライループの実装
  - [x] 2-3c. exponential backoff + full jitter の delay 計算
  - [x] 2-3d. リトライ時のログ出力（attempt 番号と待機秒数）
- [x] 2-4. `lambda_handler` 内のトピック名の動的取得: `event['records']['streamtopic-0']` → `for topic_partition, records in event['records'].items():`
  - [x] 2-4a. 外側ループ（`for topic_partition, records`）の追加
  - [x] 2-4b. 既存の `for rec in records:` ループ本体のインデント調整（1 段深くネスト）
  - [x] 2-4c. `topic_partition` のログ出力追加（`print(f'## PROCESSING: {topic_partition}')`)
- [x] 2-5. `datetime.utcfromtimestamp(timestamp)` → `datetime.fromtimestamp(timestamp, tz=timezone.utc)` に置換
- [x] 2-6. `time.sleep(5)` の削除
- [x] 2-7. `ingest_knowledge_base_documents()` の直接呼び出しを `ingest_with_backoff()` 呼び出しに置換
  - [x] 2-7a. documents リストを変数として API 呼び出しの前に定義
  - [x] 2-7b. try/except ブロックを削除（`ingest_with_backoff` 内で処理するため）
  - [x] 2-7c. レスポンスの print は `ingest_with_backoff` の戻り値で出力

### Phase 3: コード検証（ローカル）

- [x] 3-1. 変更後の YAML が有効な CloudFormation テンプレートであることを確認 → PyYAML + CFN loader で OK
- [x] 3-2. Lambda インラインコード部分のインデント（YAML `|` ブロック内の Python インデント）が正しいことを目視確認
- [x] 3-3. 変更後コードの ZipFile サイズが 4,096 バイト以内であることを最終確認 → 3,764 バイト
- [x] 3-4. `git diff` で変更箇所が 3 つの改善のみであることを確認（意図しない変更がないこと）

### Phase 4: デプロイ

- [x] 4-1. CloudFormation スタックの更新実行 → 完了
- [x] 4-2. スタック更新完了の待機 → 完了
- [x] 4-3. Lambda 関数のコードが更新されていることを確認 → 完了

### Phase 5: 動作検証

- [x] 5-1. `2.StreamIngest.ipynb` で TestData.csv の 17 レコードを MSK に送信 → 完了
- [x] 5-2. CloudWatch Logs で Lambda の実行ログを確認 → 完了
  - [x] 5-2a. `## PROCESSING: streamtopic-0` のログが出力されていること（変更 3 の検証） → 確認済み
  - [x] 5-2b. タイムスタンプが `YYYY-MM-DD HH:MM:SS` 形式であること（変更 1 の検証） → 確認済み（`2026-02-16 07:31:45`）
  - [x] 5-2c. `time.sleep(5)` 由来の 5 秒待機がなく、処理時間が大幅に短縮されていること（変更 2 の検証） → 確認済み
  - [x] 5-2d. 全 17 レコードの `## INGEST KNOWLEDGE BASE DOCUMENTS RESPONSE` が出力されていること → 確認済み（HTTP 202, status: STARTING, RetryAttempts: 0）
- [x] 5-3. Bedrock Knowledge Base に 17 件のドキュメントが取り込まれていることを確認 → 確認済み

### Phase 6: ドキュメント更新

- [x] 6-1. `CLAUDE.md` の Lambda 関数関連の記述を更新（exponential backoff、動的トピック名の反映）
- [x] 6-2. `docs/research.md` のセクション 3.5（Lambda 関数）とセクション 11, 13（制限事項）を更新
- [x] 6-3. `docs/plan.md` の TODO リストを完了済みに更新
- [ ] 6-4. 変更内容をコミット → ユーザーの指示を待つ
