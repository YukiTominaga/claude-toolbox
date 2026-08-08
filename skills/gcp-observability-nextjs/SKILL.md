---
name: gcp-observability-nextjs
description: Next.js App Router アプリケーションに OpenTelemetry ネイティブな可観測性を実装するスキル。Telemetry API (telemetry.googleapis.com) へ gRPC OTLP でトレース・メトリクス・ログの 3 シグナルを直送する構成、instrumentation.ts フック、ADC による自動トークン更新、startActiveSpan による span パターン、OTel Logs API による構造化ログ、Cloud Monitoring 向けカスタムメトリクスを扱う。GCP 可観測性、Cloud Trace、Cloud Logging、Cloud Monitoring、OTLP、opentelemetry、Next.js に関する実装を行うときに使用する。
---

# GCP Observability for Next.js App Router

Next.js (App Router) を OpenTelemetry で計装し、
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
  @grpc/grpc-js google-auth-library
```

**exporter は必ず `-grpc` を使う。** `-http` 版はヘッダーを初期化時に固定するため
アクセストークンの更新ができず、1 時間後に 401 になる。
Google 自身も「SDK から直送する場合は gRPC exporter のみを使うこと」と明記している。

`@vercel/otel` は Edge Runtime 対応と手軽さが利点だが、
exporter に `ChannelCredentials` を渡す必要があるためここでは `NodeSDK` を直接使う。

## アーキテクチャ概要

```
リクエスト
  → Next.js (instrumentation.ts で OTel 初期化済み)
      ← Next.js 本体が [http.method] [next.route] などのスパンを自動生成
  → Route Handler / Server Component / Server Action
      → tracer.startActiveSpan()         ← 手動 span
      → logger.emit() (OTel Logs API)    ← 構造化ログ（trace 相関は自動）
      → meter.createCounter() など       ← カスタムメトリクス
  → gRPC OTLP → telemetry.googleapis.com
       ├── /v1/traces  → Cloud Trace
       ├── /v1/metrics → Cloud Monitoring (prometheus.googleapis.com/... として保存)
       └── /v1/logs    → Cloud Logging (LogEntry)
```

## 1. 初期化

完全な実装は [telemetry-reference.md](telemetry-reference.md) を参照。

### instrumentation.ts（プロジェクトルート、`src/` があれば `src/`）

```typescript
export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    await import('./instrumentation.node');
  }
}
```

Next.js 15 以降 `instrumentation.ts` は安定機能。**`experimental.instrumentationHook` は不要**。
`NodeSDK` は Edge Runtime と互換がないので、必ず `NEXT_RUNTIME` で分岐して動的 import する。

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

**受信リクエストの `HttpInstrumentation` は無効化する**
Next.js 本体がルートスパン（`[http.method] [next.route]`）を作るため、
`HttpInstrumentation` で incoming も計装すると SERVER スパンが二重になる。
`ignoreIncomingRequestHook: () => true` にして、
`node:http`/`https` を使う外向き呼び出し（googleapis SDK など）の計装だけ残す。
コード内の `fetch` は Next.js 自身が `fetch [http.method] [http.url]` として計装する。

**環境変数**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com
OTEL_SERVICE_NAME=my-service
OTEL_RESOURCE_ATTRIBUTES="gcp.project_id=my-project,service.namespace=default,service.version=1.0.0"
OTEL_METRIC_EXPORT_INTERVAL=60000
GOOGLE_CLOUD_QUOTA_PROJECT=my-project  # ローカル開発 (authorized_user) のときだけ
NEXT_OTEL_VERBOSE=1                    # Next.js の詳細スパンも出す
```

`gcp.project_id` が**送信先プロジェクトを決める**。サービスアカウント認証なら
クォータプロジェクトは自動判定されるので `GOOGLE_CLOUD_QUOTA_PROJECT` は設定しない。

## 2. Next.js が自動で出すスパン

自分で書かなくても以下が出る。手動 span を足す前にこれで足りるか確認する。

| スパン名 | 内容 |
|---|---|
| `[http.method] [next.route]` | リクエストのルートスパン |
| `render route (app) [next.route]` | App Router のレンダリング |
| `executing api route (app) [next.route]` | Route Handler の実行 |
| `fetch [http.method] [http.url]` | コード内の `fetch`（`NEXT_OTEL_FETCH_DISABLED=1` で無効化可） |
| `generateMetadata [next.page]` | メタデータ生成 |

`NEXT_OTEL_VERBOSE=1` で `resolve page components` / `resolve segment modules` /
`start response` も出る。属性は `next.route` / `next.span_type` / `next.page` / `next.rsc`。

## 3. 手動 Span パターン

### 推奨: `startActiveSpan`

`startActiveSpan` はコンテキストの伝播・`span.end()` の呼び出し漏れ・二重呼び出しを
まとめて防げる。旧実装の `startSpan` + `context.with()` の入れ子は書かない。

```typescript
// app/api/something/route.ts
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';
import { logError } from '@/lib/logger';

const tracer = trace.getTracer('something-api', '1.0.0');

export async function POST(request: Request) {
  try {
    const body = await request.json();

    const result = await tracer.startActiveSpan(
      'something.process',
      { kind: SpanKind.INTERNAL },
      async (span) => {
        try {
          const r = await doWork(body);
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

    return Response.json(result);
  } catch (error) {
    logError('something.process failed', error, { route: '/api/something' });
    return Response.json({ error: '処理に失敗しました' }, { status: 500 });
  }
}
```

- `setStatus({ code: OK })` は明示しなくてよい（未設定は `UNSET` で、Cloud Trace ではエラー扱いにならない）
- `span.end()` は `finally` の 1 箇所だけ。`catch` でも呼ぶと二重実行になる
- エラーは `throw` で外に出し、レスポンス生成は外側の `catch` に集約する

### 複数スパン

`startActiveSpan` を並べれば、それぞれが Next.js のルートスパンの子（兄弟）になる。
ネストさせたい場合はコールバック内で次の `startActiveSpan` を呼ぶ。

```typescript
// Cloud Trace に表示される構造:
// POST /api/something
//   ├── something.fetchData (CLIENT)
//   └── something.transform (INTERNAL)

const data = await tracer.startActiveSpan(
  'something.fetchData',
  { kind: SpanKind.CLIENT, attributes: { 'db.system': 'bigquery' } },
  async (span) => {
    try {
      const rows = await fetchFromDB(query);
      span.setAttribute('db.rows_returned', rows.length);
      return rows;
    } finally {
      span.end();
    }
  },
);

const transformed = await tracer.startActiveSpan(
  'something.transform',
  { kind: SpanKind.INTERNAL },
  async (span) => {
    try {
      return transform(data);
    } finally {
      span.end();
    }
  },
);
```

### SpanKind の選択基準

| Kind | 使いどころ |
|------|-----------|
| `SERVER` | 受信 HTTP リクエスト（Next.js が自動設定） |
| `CLIENT` | 外部 API・DB 呼び出し（BigQuery, Discovery Engine など） |
| `INTERNAL` | LLM 推論・ビジネスロジックなど内部処理 |

## 4. 構造化ロギング (OTel Logs API)

完全な実装は [logging-reference.md](logging-reference.md) を参照。

`logger.emit()` は `context.active()` からトレースコンテキストを取るため、
**`request.headers.get('traceparent')` の取り出しもログ関数への引き回しも不要**。

```typescript
import { logError, logInfo } from '@/lib/logger';

export async function POST(request: Request) {
  logInfo('processing started');
  try {
    const result = await doWork(await request.json());
    logInfo('processing completed', { rows: result.length });
    return Response.json(result);
  } catch (error) {
    logError('processing failed', error, { route: '/api/something' });
    return Response.json({ error: '処理に失敗しました' }, { status: 500 });
  }
}
```

**Client Component から logger を import しないこと。** OTel Logs SDK は Node.js 専用。
Edge Runtime でも `LoggerProvider` は登録されないため no-op になる。

**OTLP ログ取り込みは Pre-GA**、かつ Cloud Run では monitored resource が
`cloud_run_revision` ではなく `generic_task` になる。この 2 点は受け入れて使う前提。

## 5. メトリクス

Next.js 本体はメトリクスを出さない。必要なものは自分で定義する。

```typescript
// lib/metrics.ts
import { metrics } from '@opentelemetry/api';

const meter = metrics.getMeter('my-service', '1.0.0');

// 単調増加のカウント
export const requestsProcessed = meter.createCounter('api_requests_processed', {
  description: '処理した API リクエスト数',
  unit: '{request}',
});

// 分布（instrumentation.node.ts で指数ヒストグラムに設定済み）
export const llmLatency = meter.createHistogram('api_llm_latency', {
  description: 'LLM 推論のレイテンシ',
  unit: 's',
});

// 増減する現在値
export const inflight = meter.createUpDownCounter('api_inflight_requests', {
  description: '処理中のリクエスト数',
  unit: '{request}',
});
```

```typescript
// app/api/something/route.ts
import { inflight, llmLatency, requestsProcessed } from '@/lib/metrics';

export async function POST(request: Request) {
  inflight.add(1, { route: '/api/something' });
  const startedAt = process.hrtime.bigint();
  try {
    const result = await doWork(await request.json());
    requestsProcessed.add(1, { route: '/api/something', outcome: 'success' });
    return Response.json(result);
  } catch (error) {
    requestsProcessed.add(1, { route: '/api/something', outcome: 'error' });
    return Response.json({ error: '処理に失敗しました' }, { status: 500 });
  } finally {
    llmLatency.record(Number(process.hrtime.bigint() - startedAt) / 1e9, { route: '/api/something' });
    inflight.add(-1, { route: '/api/something' });
  }
}
```

非同期に現在値を読むだけのものは Observable を使う。

```typescript
meter.createObservableGauge('api_cache_entries', { description: 'キャッシュ件数' })
  .addCallback((result) => result.observe(cache.size));
```

`lib/metrics.ts` はモジュールスコープで `getMeter()` を呼ぶため、
`instrumentation.node.ts` より先に評価されると MeterProvider 未登録の Meter を掴む。
`register()` はアプリコードより先に実行されるので通常は問題ないが、
**Client Component からは絶対に import しない**（ブラウザバンドルに混ざる）。

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
`next.route` のようなルートパターン・ステータスクラス・`outcome` など有限集合だけを属性にする。

## 6. Hono 版との違い

| 項目 | Hono | Next.js App Router |
|------|------|-------------------|
| 初期化場所 | `index.ts` 先頭で `await startTelemetry()` | `instrumentation.ts` の `register()` |
| ルートスパン | `HttpInstrumentation` + `httpInstrumentationMiddleware` | Next.js 本体が生成（`HttpInstrumentation` の incoming は無効化） |
| HTTP メトリクス | `@hono/otel` が `http.server.*` を自動生成 | 自動では出ない。必要なら自分で定義 |
| ログの呼び出し | `logInfo(message, attrs)` | `logInfo(message, attrs)`（同じ。Context 引き回し不要） |
| Runtime 分岐 | 不要 | `NEXT_RUNTIME === 'nodejs'` で分岐が必須 |

## 7. IAM 権限

| ロール | 用途 |
|--------|------|
| `roles/telemetry.writer` | Telemetry API へのログ・メトリクス・トレース書き込み（3 シグナルまとめて） |
| `roles/telemetry.tracesWriter` / `roles/telemetry.metricsWriter` / `roles/telemetry.logsWriter` | シグナルを絞る場合 |
| `roles/serviceusage.serviceUsageConsumer` | クォータプロジェクトに対して。`x-goog-user-project` を送る場合に必要 |

`gcloud services enable telemetry.googleapis.com` を忘れないこと。

## 8. よくあるトラブル

| 症状 | 原因 | 対処 |
|------|------|------|
| 1時間後に 401 | `-http` 版 exporter を使っている | `-grpc` 版 + `createFromGoogleCredential` に変える |
| ログが 1 件も出ない | `LoggerProvider` 未登録（`logRecordProcessors` 未設定 / Edge Runtime で実行） | `NodeSDK` の設定と `NEXT_RUNTIME` 分岐を確認する |
| SERVER スパンが二重に出る | `HttpInstrumentation` が incoming も計装している | `ignoreIncomingRequestHook: () => true` |
| `register()` が呼ばれない | ファイル位置が違う（`app/` の中に置いた / `src/` 使用時にルートに置いた） | ルート、または `src/` 直下に置く |
| Edge Runtime でクラッシュ | `instrumentation.node.ts` を Edge でも import している | `NEXT_RUNTIME === 'nodejs'` で分岐する |
| ビルドが壊れる / 計装が効かない | 計装パッケージが Server Components バンドルに取り込まれている | `serverExternalPackages` に追加する |
| Cloud Run でログ・メトリクスが欠ける | CPU スロットリングで Batch の定期 flush が走らない | `--no-cpu-throttling` を付けるか `scheduledDelayMillis` を短くする |
| 403 Forbidden | `x-goog-user-project` を送っている / API 未有効化 | `GOOGLE_CLOUD_QUOTA_PROJECT` を外すか `roles/serviceusage.serviceUsageConsumer` を付与。`gcloud services enable telemetry.googleapis.com` |
| メトリクスが Cloud Monitoring に出ない | 名前・ラベルが命名規則に違反して拒否されている | `[a-zA-Z][a-zA-Z0-9_:./-]*` / `[a-zA-Z_][a-zA-Z0-9_.]*` に合わせる |
| メトリクスが `prometheus.googleapis.com/...` にある | 仕様。OTLP メトリクスは Prometheus 形式で保存される | その名前で検索する |
| トレースが表示されない | `gcp.project_id` 未設定 / IAM 不足 | `OTEL_RESOURCE_ATTRIBUTES` と `roles/telemetry.writer` を確認 |
| span データが壊れている | `catch` と `finally` の両方で `span.end()` | `finally` のみで呼ぶ |
| 原因が特定できない | — | `OTEL_LOG_LEVEL=debug` / `NEXT_OTEL_VERBOSE=1` |
