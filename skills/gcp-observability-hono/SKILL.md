---
name: gcp-observability-hono
description: Hono + Node.js アプリケーションに OpenTelemetry ネイティブな可観測性を実装するスキル。Telemetry API (telemetry.googleapis.com) へ gRPC OTLP でトレース・メトリクス・ログの 3 シグナルを直送する構成、ADC による自動トークン更新、startActiveSpan による span パターン、OTel Logs API による構造化ログ、Cloud Monitoring 向けカスタムメトリクスを扱う。GCP 可観測性、Cloud Trace、Cloud Logging、Cloud Monitoring、OTLP、opentelemetry、hono に関する実装を行うときに使用する。
---

# GCP Observability for Hono

Hono (Node.js) アプリケーションを OpenTelemetry で計装し、
**トレース・メトリクス・ログすべてを Telemetry API (`telemetry.googleapis.com`) に OTLP で直送**するパターン。

Cloud Logging / Cloud Monitoring 独自 API 向けの exporter や、
`logging.googleapis.com/*` フィールドを手で組む実装は使わない。

## 依存パッケージ

```bash
npm install @opentelemetry/api @opentelemetry/api-logs @opentelemetry/core \
  @opentelemetry/sdk-node @opentelemetry/sdk-logs @opentelemetry/sdk-metrics \
  @opentelemetry/resources @opentelemetry/resource-detector-gcp \
  @opentelemetry/instrumentation-http \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/exporter-metrics-otlp-grpc \
  @opentelemetry/exporter-logs-otlp-grpc \
  @google-cloud/opentelemetry-cloud-trace-propagator \
  @grpc/grpc-js @hono/otel google-auth-library
```

**exporter は必ず `-grpc` を使う。** `-http` 版はヘッダーを初期化時に固定するため
アクセストークンの更新ができず、1 時間後に 401 になる。
Google 自身も「SDK から直送する場合は gRPC exporter のみを使うこと」と明記している。

## アーキテクチャ概要

```
リクエスト
  → HttpInstrumentation (NodeSDK, http モジュールレベル)  ← HTTP スパン
  → httpInstrumentationMiddleware (@hono/otel)            ← ルート名をスパン名に反映
                                                             + http.server.* メトリクス
  → Hono Route Handler
      → tracer.startActiveSpan()         ← 手動 span
      → logger.emit() (OTel Logs API)    ← 構造化ログ（trace 相関は自動）
      → meter.createCounter() など       ← カスタムメトリクス
  → gRPC OTLP → telemetry.googleapis.com
       ├── /v1/traces  → Cloud Trace
       ├── /v1/metrics → Cloud Monitoring (prometheus.googleapis.com/... として保存)
       └── /v1/logs    → Cloud Logging (LogEntry)
```

## 1. 初期化 (src/config/telemetry.ts)

完全な実装は [telemetry-reference.md](telemetry-reference.md) を参照。

### 設計ポイント

**認証は `createFromGoogleCredential` に任せる**

```typescript
credentials: credentials.combineChannelCredentials(
  credentials.createSsl(),
  credentials.createFromGoogleCredential(authClient),
),
```

これがリクエストごとに `authClient.getRequestHeaders()` を呼ぶので、
トークンの更新も `x-goog-user-project` の付与も google-auth-library 側で完結する。
**自前のトークンキャッシュや exporter 再生成ラッパーを書いてはいけない**（旧実装の負債）。

**3 シグナルで同じ `ChannelCredentials` を共有する**
`traceExporter` / `metricReaders` / `logRecordProcessors` に同じインスタンスを渡す。

**`index.ts` の先頭で `await startTelemetry()` を呼ぶ**

```typescript
// src/index.ts
import { startTelemetry, stopTelemetry } from './config/telemetry.js';
await startTelemetry();

import { serve } from '@hono/node-server';
// ...
```

`logs.getLogger()` は `LoggerProvider` 未登録なら no-op になり**ログが黙って消える**。
初期化を待たずにログを出す経路を作らないこと。

**SIGTERM で「サーバーを閉じる → `sdk.shutdown()`」の順に落とす**
逆順にすると処理中リクエストのスパン・ログが失われる。

**環境変数**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com
OTEL_SERVICE_NAME=my-service
OTEL_RESOURCE_ATTRIBUTES="gcp.project_id=my-project,service.namespace=default,service.version=1.0.0"
OTEL_METRIC_EXPORT_INTERVAL=60000
GOOGLE_CLOUD_QUOTA_PROJECT=my-project  # ローカル開発 (authorized_user) のときだけ
```

`gcp.project_id` が**送信先プロジェクトを決める**。サービスアカウント認証なら
クォータプロジェクトは自動判定されるので `GOOGLE_CLOUD_QUOTA_PROJECT` は設定しない。

## 2. Hono ミドルウェア設定 (index.ts)

`HttpInstrumentation`（NodeSDK）と `httpInstrumentationMiddleware`（`@hono/otel`）の両方を使う。
前者が Node.js HTTP レベルのスパンを作り、後者が Hono のルートパターン
（`GET /tools/qa/summary` など）をスパン名に反映する。

```typescript
import { httpInstrumentationMiddleware } from '@hono/otel';

const otelMiddleware = httpInstrumentationMiddleware({ captureActiveRequests: true });
app.use('*', (c, next) => {
  if (c.req.path === '/health') return next();  // ヘルスチェックは除外
  return otelMiddleware(c, next);
});

app.get('/health', (c) => c.json({ status: 'ok' }));
```

`HttpInstrumentation` 側でも同じパスを除外する。

```typescript
new HttpInstrumentation({
  ignoreIncomingRequestHook: (req) => req.url === '/health',
}),
```

`@hono/otel` はグローバル MeterProvider が登録されていれば
`http.server.request.duration` と `http.server.active_requests`（`captureActiveRequests: true` のとき）
を自動で出す。**メトリクスのために自分でカウンタを足す必要はない。**

Cloud Trace 上の構造:

```
GET /tools/qa/summary        ← httpInstrumentationMiddleware
  ├── qa.generateSearchQuery
  └── qa.summarize
```

## 3. 手動 Span パターン

### 推奨: `startActiveSpan`

`startActiveSpan` はコンテキストの伝播・`span.end()` の呼び出し漏れ・二重呼び出しを
まとめて防げる。旧実装の `startSpan` + `context.with()` の入れ子は書かない。

```typescript
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';

const tracer = trace.getTracer('my-route', '1.0.0');

app.post('/something', async (c) => {
  try {
    const result = await tracer.startActiveSpan(
      'my-operation',
      { kind: SpanKind.CLIENT, attributes: { 'db.system': 'bigquery' } },
      async (span) => {
        try {
          const r = await externalCall();
          span.setAttribute('result.count', r.length);
          return r;
        } catch (error) {
          const err = error instanceof Error ? error : new Error(String(error));
          span.recordException(err);
          span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
          throw err;
        } finally {
          span.end();
        }
      },
    );
    return c.json({ result });
  } catch (error) {
    logError('my-operation failed', error);
    return c.json({ error: '処理に失敗しました' }, 500);
  }
});
```

- `setStatus({ code: OK })` は明示しなくてよい（未設定は `UNSET` で、Cloud Trace ではエラー扱いにならない）
- `span.end()` は `finally` の 1 箇所だけ。`catch` でも呼ぶと二重実行になる
- エラーは `throw` で外に出し、レスポンス生成は外側の `catch` に集約する

### 複数スパン（シーケンシャル）

`startActiveSpan` を並べれば、それぞれが HTTP スパンの直接の子（兄弟）になる。

```typescript
app.post('/summary', zValidator('json', schema), async (c) => {
  const { question } = c.req.valid('json');

  const query = await tracer.startActiveSpan(
    'qa.generateSearchQuery',
    { kind: SpanKind.INTERNAL, attributes: { 'llm.question': question } },
    async (span) => {
      try {
        const q = await generateSearchQuery(question);
        span.setAttribute('llm.generated_query', q);
        logInfo('qa.generateSearchQuery: completed', { query: q });
        return q;
      } finally {
        span.end();
      }
    },
  );

  const result = await tracer.startActiveSpan(
    'qa.summarize',
    { kind: SpanKind.CLIENT, attributes: { 'search.query': query } },
    async (span) => {
      try {
        const r = await summarize(query);
        span.setAttribute('search.result_count', r.results.length);
        return r;
      } finally {
        span.end();
      }
    },
  );

  return c.json({ query, result });
});
```

ネストさせたい場合は `startActiveSpan` のコールバック内で次の `startActiveSpan` を呼ぶだけ。

### SpanKind の選択基準

| Kind | 使いどころ |
|------|-----------|
| `SERVER` | 受信 HTTP リクエスト（`httpInstrumentationMiddleware` が自動設定） |
| `CLIENT` | 外部 API・DB 呼び出し（BigQuery, Discovery Engine など） |
| `INTERNAL` | LLM 推論・ビジネスロジックなど内部処理 |

## 4. 構造化ロギング (OTel Logs API)

完全な実装は [logging-reference.md](logging-reference.md) を参照。

`logger.emit()` は `context.active()` からトレースコンテキストを取るため、
**`traceparent` / `X-Cloud-Trace-Context` の手動パースも Hono `Context` の引き回しも不要**。

```typescript
import { logError, logInfo } from '../config/logger.js';

app.post('/something', async (c) => {
  logInfo('processing started', { inputSize: 42 });
  try {
    const result = await doWork();
    logInfo('processing completed', { rows: result.length });
    return c.json({ result });
  } catch (error) {
    logError('processing failed', error, { route: '/something' });
    return c.json({ error: '処理に失敗しました' }, 500);
  }
});
```

Telemetry API 側で `LogEntry.trace` / `spanId` / `traceSampled` / `severity` が埋まる。

**OTLP ログ取り込みは Pre-GA**、かつ Cloud Run では monitored resource が
`cloud_run_revision` ではなく `generic_task` になる。この 2 点は受け入れて使う前提。

## 5. メトリクス

### 自動計装で取れるもの

`metricReaders` を設定するだけで以下が Cloud Monitoring に流れる。

- `http.server.request.duration` / `http.server.active_requests`（`@hono/otel`）
- `http.client.request.duration`（`HttpInstrumentation`）

### カスタムメトリクス

```typescript
import { metrics } from '@opentelemetry/api';

const meter = metrics.getMeter('my-service', '1.0.0');

// 単調増加のカウント
const requestsProcessed = meter.createCounter('qa_requests_processed', {
  description: '処理した QA リクエスト数',
  unit: '{request}',
});

// 分布（telemetry.ts で指数ヒストグラムに設定済み）
const llmLatency = meter.createHistogram('qa_llm_latency', {
  description: 'LLM 推論のレイテンシ',
  unit: 's',
});

// 増減する現在値
const inflight = meter.createUpDownCounter('qa_inflight_requests', {
  description: '処理中の QA リクエスト数',
  unit: '{request}',
});

// 使用側
inflight.add(1, { route: '/summary' });
const startedAt = process.hrtime.bigint();
try {
  await summarize(query);
  requestsProcessed.add(1, { route: '/summary', outcome: 'success' });
} catch (error) {
  requestsProcessed.add(1, { route: '/summary', outcome: 'error' });
  throw error;
} finally {
  llmLatency.record(Number(process.hrtime.bigint() - startedAt) / 1e9, { route: '/summary' });
  inflight.add(-1, { route: '/summary' });
}
```

非同期に現在値を読むだけのものは Observable を使う。

```typescript
meter.createObservableGauge('qa_cache_entries', { description: 'キャッシュ件数' })
  .addCallback((result) => result.observe(cache.size));
```

### 命名と属性の規約（Cloud Monitoring 側の制約）

| 項目 | 制約 |
|------|------|
| メトリクス名 | `[a-zA-Z][a-zA-Z0-9_:./-]*` に一致しないと**拒否される** |
| ラベルキー | `[a-zA-Z_][a-zA-Z0-9_.]*` に一致しないと拒否される |
| ラベル数 | 1 メトリクスあたり 200 まで |
| 保存名 | `prometheus.googleapis.com/<metric_name>/<suffix>`（suffix は点の種別で決まる） |
| エクスポート間隔 | 下限 5s。既定 60s のままで十分 |
| 取り込みクォータ | 既定 60,000 req/min |

**属性のカーディナリティに注意する。** ユーザー ID・リクエスト ID・生の URL パスなど
値が無限に増えるものを属性にすると時系列が爆発し、コストとクエリ性能を壊す。
ルートパターン・ステータスクラス・`outcome` のような有限集合だけを属性にする。

## 6. IAM 権限

| ロール | 用途 |
|--------|------|
| `roles/telemetry.writer` | Telemetry API へのログ・メトリクス・トレース書き込み（3 シグナルまとめて） |
| `roles/telemetry.tracesWriter` / `roles/telemetry.metricsWriter` / `roles/telemetry.logsWriter` | シグナルを絞る場合 |
| `roles/serviceusage.serviceUsageConsumer` | クォータプロジェクトに対して。`x-goog-user-project` を送る場合に必要 |

`gcloud services enable telemetry.googleapis.com` を忘れないこと。

## 7. よくあるトラブル

| 症状 | 原因 | 対処 |
|------|------|------|
| 1時間後に 401 | `-http` 版 exporter を使っている | `-grpc` 版 + `createFromGoogleCredential` に変える |
| ログが 1 件も出ない | `LoggerProvider` 未登録（`startTelemetry()` 前にログを出した / `logRecordProcessors` 未設定） | 初期化順序と `NodeSDK` の設定を確認する |
| Cloud Run でログ・メトリクスが欠ける | CPU スロットリングで Batch の定期 flush が走らない | `--no-cpu-throttling` を付けるか `scheduledDelayMillis` を短くする |
| デプロイ直後の数リクエスト分が消える | SIGTERM で flush していない | サーバーを閉じてから `await sdk.shutdown()` |
| 403 Forbidden | `x-goog-user-project` を送っている / API 未有効化 | `GOOGLE_CLOUD_QUOTA_PROJECT` を外すか `roles/serviceusage.serviceUsageConsumer` を付与。`gcloud services enable telemetry.googleapis.com` |
| メトリクスが Cloud Monitoring に出ない | 名前・ラベルが命名規則に違反して拒否されている | `[a-zA-Z][a-zA-Z0-9_:./-]*` / `[a-zA-Z_][a-zA-Z0-9_.]*` に合わせる |
| メトリクスが `prometheus.googleapis.com/...` にある | 仕様。OTLP メトリクスは Prometheus 形式で保存される | その名前で検索する |
| トレースが表示されない | `gcp.project_id` 未設定 / IAM 不足 | `OTEL_RESOURCE_ATTRIBUTES` と `roles/telemetry.writer` を確認 |
| ログに trace が紐づかない | アクティブな span の外でログを出している | `startActiveSpan` のコールバック内、またはミドルウェア配下で出す |
| span データが壊れている | `catch` と `finally` の両方で `span.end()` | `finally` のみで呼ぶ |
| 原因が特定できない | — | `OTEL_LOG_LEVEL=debug` で SDK 内部ログを出す |
