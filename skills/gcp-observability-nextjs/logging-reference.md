# ログ — OTel Logs API 実装リファレンス

## 旧実装（stdout JSON + 手書き trace 相関）を捨てる理由

旧 `LoggingService` は以下を手で書いていた。**すべて不要になる。**

| 旧実装でやっていたこと | OTLP 直送での扱い |
|---|---|
| `request.headers.get('traceparent')` を split して traceId を抽出 | `logger.emit()` が `context.active()` から自動取得 |
| `x-cloud-trace-context` を正規表現でパース | 同上（伝播は Propagator の責務） |
| `logging.googleapis.com/trace` を `projects/.../traces/...` 形式で組む | Telemetry API が `LogEntry.trace` を組む |
| `logging.googleapis.com/spanId` / `traceSampled` を付与 | Telemetry API が `spanId` / `traceSampled` を埋める |
| ログ関数に `traceparent` / `xCloudTraceContext` を毎回渡す | 引数不要 |
| `console.log(JSON.stringify(...))` | exporter が OTLP で送る |
| severity 文字列の管理 | `SeverityNumber` を渡すだけ |

`logger.emit()` は `logRecord.context` が未指定なら `context.active()` を使う
（`@opentelemetry/sdk-logs` の `Logger#emit`）。
Next.js は Route Handler / Server Component の実行を自前のスパンで包むため、
**ハンドラ内で出したログは何もしなくてもそのリクエストのトレースに紐づく**。

## lib/logger.ts

```typescript
import { logs, SeverityNumber } from '@opentelemetry/api-logs';
import type { LogAttributes } from '@opentelemetry/api-logs';

const logger = logs.getLogger('app', '1.0.0');

export function logDebug(message: string, attributes?: LogAttributes): void {
  logger.emit({ severityNumber: SeverityNumber.DEBUG, severityText: 'DEBUG', body: message, attributes });
}

export function logInfo(message: string, attributes?: LogAttributes): void {
  logger.emit({ severityNumber: SeverityNumber.INFO, severityText: 'INFO', body: message, attributes });
}

export function logWarn(message: string, attributes?: LogAttributes): void {
  logger.emit({ severityNumber: SeverityNumber.WARN, severityText: 'WARN', body: message, attributes });
}

/**
 * エラーは exception.* セマンティック規約に沿った属性を付ける。
 * エラーを黙って捨てず、必ず型・メッセージ・スタックを残す。
 */
export function logError(message: string, error: unknown, attributes?: LogAttributes): void {
  const err = error instanceof Error ? error : new Error(String(error));
  logger.emit({
    severityNumber: SeverityNumber.ERROR,
    severityText: 'ERROR',
    body: message,
    attributes: {
      ...attributes,
      'exception.type': err.name,
      'exception.message': err.message,
      ...(err.stack ? { 'exception.stacktrace': err.stack } : {}),
    },
  });
}
```

`logs.getLogger()` はグローバルの `LoggerProvider` を引く。
`NodeSDK` に `logRecordProcessors` を渡していればそれが登録済みになる。
未設定だと no-op になり**ログが黙って消える**。

**Client Component からこのモジュールを import しないこと。** OTel Logs SDK は Node.js 専用で、
ブラウザバンドルに混ざると壊れる。サーバー側（Route Handler / Server Component / Server Action）専用に保つ。
Edge Runtime でも `LoggerProvider` は登録されないため no-op になる。

## Route Handler での使い方

```typescript
// app/api/something/route.ts
import { logError, logInfo } from '@/lib/logger';

export async function POST(request: Request) {
  // request.headers から traceparent を取り出す必要はない
  logInfo('processing started');

  try {
    const body = await request.json();
    const result = await doWork(body);
    logInfo('processing completed', { rows: result.length });
    return Response.json(result);
  } catch (error) {
    logError('processing failed', error, { route: '/api/something' });
    return Response.json({ error: '処理に失敗しました' }, { status: 500 });
  }
}
```

## Server Component での使い方

```typescript
import { logInfo } from '@/lib/logger';

export default async function Page() {
  const data = await fetchData();
  logInfo('page rendered', { itemCount: data.length });
  return <List items={data} />;
}
```

ビルド時（静的生成）にも実行されることに注意する。
リクエスト時だけログを出したい場合は `dynamic = 'force-dynamic'` などレンダリングモードを確認する。

## severity の対応

Telemetry API は `severityNumber` を優先し、無ければ `severityText`、両方無ければ `DEFAULT` にする。

| `SeverityNumber` | Cloud Logging severity |
|---|---|
| `TRACE`〜`TRACE4` (1–4) | `DEBUG` |
| `DEBUG`〜`DEBUG4` (5–8) | `DEBUG` |
| `INFO` / `INFO2` (9–10) | `INFO` |
| `INFO3` / `INFO4` (11–12) | `NOTICE` |
| `WARN`〜`WARN4` (13–16) | `WARNING` |
| `ERROR`〜`ERROR4` (17–20) | `ERROR` |
| `FATAL`〜`FATAL4` (21–24) | `CRITICAL` / `ALERT` / `EMERGENCY` |

## body と logName のマッピング

| OTLP LogRecord | Cloud Logging `LogEntry` |
|---|---|
| `body` が文字列 | `textPayload` |
| `body` が KeyValueList | `jsonPayload` |
| `attributes` | `labels`（マップ済みフィールドを除いたもの） |
| `traceId` / `spanId` / `flags` 最下位ビット | `trace` / `spanId` / `traceSampled` |
| `timestamp` → `observedTimestamp` → 取り込み時刻 | `timestamp`（この優先順） |
| その他マップされないもの | `otel` フィールド |

`logName` は `eventName` が最優先。無い場合は属性の優先順リスト
（`log.name`, `gcp.log.name`, `log_name`, `gcp.log_name`, `logging.googleapis.com/logName`,
`service.name`, `gcp.service.name`, `service_name`, `gcp.service_name`,
`event.name`, `gcp.event.name`, `event_name`, `gcp.event_name`）から決まる。
`OTEL_SERVICE_NAME` を設定していれば `service.name` で落ち着くので、
特に分けたいログだけ `eventName` を明示すればよい。

構造化データを `jsonPayload` に入れたい場合は body をオブジェクトにする。

```typescript
logger.emit({
  severityNumber: SeverityNumber.INFO,
  eventName: 'request-body',      // logName になる
  body: { path: new URL(request.url).pathname, method: request.method },
});
```

## ログ量とコストの注意

Telemetry API は各エントリの `otel` フィールドに resource / scope / entity のコピーを入れるため、
エントリ単位のバイト数が増える。削るには collector 経由で `gcp.use_legacy_mapping` を使う
（SDK 直送では指定できないので、コストが問題になった時点でサイドカー構成を検討する）。

## Error Reporting について（未検証）

旧実装は `@type: type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent`
と `stack_trace` を `jsonPayload` に入れて Error Reporting に拾わせていた。
OTLP 経由でも body を KeyValueList にすれば同じ `jsonPayload` は作れるが、
**OTLP 取り込み経路での Error Reporting 連携は Google の公式ドキュメントに記載がなく、この構成では未検証**。
Error Reporting を確実に使いたい場合は、スパン側の `span.recordException()` と
Error Reporting の他の取り込み経路を併用し、実際に検出されるか確認すること。

## 制限事項

OTLP ログの取り込みは **Pre-GA（Pre-GA Offerings Terms 適用）**。
GA が要件なら stdout の構造化ログ（Cloud Logging エージェント経由）に戻す判断もあり得る。
その場合も trace 相関の手書きは不要で、pino + `@opentelemetry/instrumentation-pino`
（`disableLogSending: true`）で `trace_id` / `span_id` を自動注入し、
pino の formatter で `logging.googleapis.com/*` に変換する形にできる。
