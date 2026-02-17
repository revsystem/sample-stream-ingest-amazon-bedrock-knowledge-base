# MSK と Lambda の連携の仕組み

本ドキュメントは、Amazon MSK（Managed Streaming for Apache Kafka）と AWS Lambda が Event Source Mapping を通じてどのように連携するかを記録したものである。本プロジェクト固有の設定についても併せて整理する。

---

## 1. 全体像: プル型のイベント駆動モデル

MSK が Lambda を直接「キック」しているわけではない。Lambda 側の Event Source Mapping というコンポーネントが内部的に Kafka コンシューマーとして動作し、MSK のトピックをポーリングしている。

処理の流れは以下のとおり。

1. プロデューサーが MSK のトピックにメッセージを書き込む
2. Event Source Mapping のポーラーがトピックパーティションからメッセージをプルする
3. ポーラーがバッチを組み立て、Lambda 関数を同期的に Invoke する
4. Lambda がバッチを正常に処理すると、ポーラーがオフセットをコミットし、次のバッチに進む

SQS のような「プッシュ型」に見えるが、内部的にはポーリングベースのプルモデルである。

---

## 2. MSK のメッセージ保持

Kafka はメッセージキュー（SQS など）とは異なるログベースのモデルを採用している。

| 特性 | SQS | MSK (Kafka) |
|------|-----|-------------|
| メッセージの消費後 | 削除される | ログに残る（retention period まで） |
| 消費の追跡 | Visibility Timeout | コンシューマーグループのオフセット |
| デフォルト保持期間 | 4日（最大14日） | 7日（設定変更可能） |
| 複数コンシューマー | メッセージは1回だけ配信 | 異なるコンシューマーグループが独立して読める |

Kafka ではコンシューマー（Event Source Mapping）がどこまで読んだかをオフセットで追跡する。処理成功後にオフセットをコミットして先に進み、失敗時はオフセットを進めないことでリトライを実現する。

---

## 3. 失敗時のリトライ挙動

MSK はストリームベースのイベントソース扱いであり、Lambda invocation が失敗した場合（関数エラー、タイムアウト等）、Event Source Mapping は以下のように動作する。

### 3.1 デフォルトの挙動

失敗したバッチに対してオフセットを進めず、同じバッチを繰り返し再試行する。デフォルトではリトライ回数に上限がなく、成功するまで（または手動で介入するまで）無限にリトライする。

この間、該当パーティションの後続メッセージの処理はブロックされる。これは Kafka のパーティション内メッセージ順序を保証するための設計である。

### 3.2 リトライを制御するパラメータ

Event Source Mapping 作成時に以下のパラメータで挙動を制御できる。

| パラメータ | 説明 | デフォルト値 |
|-----------|------|-------------|
| `MaximumRetryAttempts` | リトライの最大回数。-1 で無限、0 でリトライなし | -1（無限） |
| `BisectBatchOnFunctionError` | 失敗時にバッチを半分に分割して原因レコードを絞り込む | false |
| `MaximumRecordAgeInSeconds` | この秒数より古いレコードは処理をスキップする | -1（無制限） |
| `OnFailure.Destination` | リトライを使い切った場合の送信先（SQS ARN または SNS ARN） | なし |

### 3.3 リトライが続いた場合の影響

リトライ中はそのパーティションのオフセットが進まないため、新しいメッセージも処理されない。パーティションが1つしかない場合はトピック全体の処理が停止する。

対策としては以下が考えられる。

- `MaximumRetryAttempts` を有限に設定し、`OnFailure` で DLQ（Dead Letter Queue）に失敗レコードを退避させる
- `BisectBatchOnFunctionError` を有効にして、問題のあるレコードを特定する
- CloudWatch メトリクス `IteratorAge` を監視して、処理遅延を検知する

---

## 4. 本プロジェクトの設定

本プロジェクトの Event Source Mapping は `notebooks/1.Setup.ipynb` で以下のように作成している。

```python
lambda_client.create_event_source_mapping(
    EventSourceArn=MSKClusterArn,
    FunctionName=LambdaFunctionName,
    StartingPosition='LATEST',
    Enabled=True,
    Topics=['streamtopic']
)
```

| 設定項目 | 値 | 意味 |
|---------|-----|------|
| StartingPosition | `LATEST` | マッピング作成後に到着した新しいメッセージのみ処理 |
| Topics | `streamtopic` | 1トピックのみ |
| パーティション数 | 1 | `1.Setup.ipynb` で `PartitionCount=1` として作成 |
| MaximumRetryAttempts | 未設定（デフォルト: 無限） | 失敗時は無限にリトライ |
| BisectBatchOnFunctionError | 未設定（デフォルト: false） | バッチ分割なし |
| OnFailure | 未設定 | DLQ なし |

サンプルプロジェクトとして検証用途のため、リトライ制御やDLQは設定していない。本番環境に適用する場合は `MaximumRetryAttempts` と `OnFailure` の設定を検討すること。

---

## 5. 参考リンク

- [Using Lambda with Amazon MSK](https://docs.aws.amazon.com/lambda/latest/dg/with-msk.html) — Lambda と MSK の連携に関する公式ドキュメント
- [Lambda event source mapping](https://docs.aws.amazon.com/lambda/latest/dg/invocation-eventsourcemapping.html) — Event Source Mapping の概要と設定パラメータ
- [Lambda reserved concurrency](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html) — 予約同時実行数の設定
