# telemetry 初期化 — 完全実装リファレンス（traces / metrics / logs）

Telemetry API (`telemetry.googleapis.com`) に **gRPC OTLP で 3 シグナルすべてを直送**する構成。

## なぜ gRPC なのか

Google は「SDK から直送する場合は gRPC exporter のみを使い、HTTP exporter は使わないこと」と明記している。
理由は HTTP exporter がヘッダーを初期化時に固定するため、アクセストークンを動的に更新できないこと。

gRPC なら CallCredentials が**リクエストごとに `authClient.getRequestHeaders()` を呼ぶ**ため、
google-auth-library 側でトークンの期限管理・更新が完結する。
自前のトークンキャッシュ・exporter 再生成ラッパーは不要。

## 落とし穴: `createFromGoogleCredential` は使えない

Google の公式サンプルは `credentials.createFromGoogleCredential(authClient)` を使っているが、
**google-auth-library v10 以降では認証ヘッダーが無音で落ちる。**

- grpc-js の実装は `Object.keys(headers)` でヘッダーを列挙している
- google-auth-library は v10 で `getRequestHeaders()` の戻り値を web の `Headers` に変更した
- `Object.keys(new Headers({...}))` は `[]` を返す → Metadata が空 → `UNAUTHENTICATED`

型エラーとしても出る（`Promise<Headers>` が `Promise<{[k:string]:string}>` に代入できない）ので、
`as any` で潰さないこと。`createFromMetadataGenerator` で `Headers` を自分で展開する。

## instrumentation.ts（プロジェクトルート、`src/` があれば `src/`）

`register()` はサーバー起動時に一度だけ呼ばれる。
`NodeSDK` は Edge Runtime と互換がないため、Node.js ランタイム限定で動的 import する。

```typescript
export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    await import('./instrumentation.node');
  }
}
```

Next.js 15 以降 `instrumentation.ts` は安定機能。`experimental.instrumentationHook` は不要。

## instrumentation.node.ts

```typescript
import { credentials, Metadata } from '@grpc/grpc-js';
import { CloudPropagator } from '@google-cloud/opentelemetry-cloud-trace-propagator';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';
import { CompositePropagator, W3CTraceContextPropagator } from '@opentelemetry/core';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { gcpDetector } from '@opentelemetry/resource-detector-gcp';
import { envDetector, hostDetector, processDetector } from '@opentelemetry/resources';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import {
  AggregationType,
  InstrumentType,
  PeriodicExportingMetricReader,
} from '@opentelemetry/sdk-metrics';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { GoogleAuth } from 'google-auth-library';

diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.INFO);

const auth = new GoogleAuth({ scopes: 'https://www.googleapis.com/auth/cloud-platform' });
const authClient = await auth.getClient();

// export のたびに getRequestHeaders() が呼ばれるので、
// トークン更新と x-goog-user-project の付与は google-auth-library に任せられる。
// createFromGoogleCredential() は使わない（Object.keys(Headers) が空になり認証が落ちる）
const callCredentials = credentials.createFromMetadataGenerator((options, callback) => {
  authClient
    .getRequestHeaders(options.service_url)
    .then((headers) => {
      const metadata = new Metadata();
      // v10 以降は web Headers、それ以前はプレーンオブジェクト
      const entries =
        headers instanceof Headers
          ? [...headers.entries()]
          : Object.entries(headers as Record<string, string>);
      for (const [key, value] of entries) {
        metadata.add(key, value);
      }
      callback(null, metadata);
    })
    .catch((error: unknown) => {
      // 認証失敗を握り潰すと「テレメトリが出ない」だけの謎の症状になる
      callback(error instanceof Error ? error : new Error(String(error)));
    });
});

const channelCredentials = credentials.combineChannelCredentials(
  credentials.createSsl(),
  callCredentials,
);

const sdk = new NodeSDK({
  // resource: gcp.project_id が送信先プロジェクトを決める（OTEL_RESOURCE_ATTRIBUTES で渡す）
  resourceDetectors: [envDetector, hostDetector, processDetector, gcpDetector],

  // --- traces ---
  traceExporter: new OTLPTraceExporter({ credentials: channelCredentials }),
  instrumentations: [
    // 受信リクエストのスパンは Next.js 自身が作るので incoming は無効化し、
    // node:http/https を使う外向き呼び出し（googleapis SDK など）だけ計装する
    new HttpInstrumentation({ ignoreIncomingRequestHook: () => true }),
  ],
  textMapPropagator: new CompositePropagator({
    propagators: [new W3CTraceContextPropagator(), new CloudPropagator()],
  }),

  // --- metrics ---
  metricReaders: [
    new PeriodicExportingMetricReader({
      // Cloud Monitoring の下限は 5s。既定は 60s
      exportIntervalMillis: Number(process.env.OTEL_METRIC_EXPORT_INTERVAL) || 60_000,
      exporter: new OTLPMetricExporter({
        credentials: channelCredentials,
        // Histogram は指数ヒストグラムにする（バケット境界を自前で決めなくて済む）
        aggregationPreference: (instrumentType: InstrumentType) =>
          instrumentType === InstrumentType.HISTOGRAM
            ? { type: AggregationType.EXPONENTIAL_HISTOGRAM }
            : { type: AggregationType.DEFAULT },
      }),
    }),
  ],

  // --- logs ---
  logRecordProcessors: [
    new BatchLogRecordProcessor({
      exporter: new OTLPLogExporter({ credentials: channelCredentials }),
      scheduledDelayMillis: 1_000,  // 既定 1000ms。Cloud Run では伸ばさない
      maxExportBatchSize: 512,
    }),
  ],
});

try {
  sdk.start();
  diag.info('[OTel] SDK started');
} catch (error) {
  // 可観測性の初期化失敗でアプリを落とさない。ただし黙って握り潰さず必ず出す
  diag.error('[OTel] failed to initialize', error);
}

// Cloud Run は SIGTERM 後 10 秒で強制終了する。span / metric / log を flush する
process.on('SIGTERM', () => {
  sdk
    .shutdown()
    .then(() => diag.info('[OTel] SDK shut down'))
    .catch((error) => diag.error('[OTel] shutdown failed', error));
});
```

`OTEL_EXPORTER_OTLP_ENDPOINT` を設定しておけば `url` の明示は不要。
`https://` スキームなので exporter は TLS 前提で解決し、コードで渡した `credentials` が優先される。
gRPC ではパス（`/v1/traces` など）は付かない — シグナルの振り分けは gRPC サービスメソッドで行われる。

## next.config.ts

`@opentelemetry/instrumentation` が使う `require-in-the-middle` / `import-in-the-middle` は
Next.js の既定の external パッケージリストに入っているため、通常は追加設定なしで動く。
自前で追加した計装パッケージがバンドルされて動かない場合のみ external に追加する。

```typescript
import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // 必要になった場合のみ
  // serverExternalPackages: ['@opentelemetry/instrumentation'],
};

export default nextConfig;
```

## 環境変数

```bash
# 送信先
OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com

# リソース属性。gcp.project_id が送信先プロジェクトを決める
OTEL_SERVICE_NAME=my-service
OTEL_RESOURCE_ATTRIBUTES="gcp.project_id=my-project,service.namespace=default,service.version=1.0.0"

# メトリクスのエクスポート間隔（ms）。Cloud Monitoring の下限は 5000
OTEL_METRIC_EXPORT_INTERVAL=60000

# ローカル開発（authorized_user 資格情報）のときだけ必要
GOOGLE_CLOUD_QUOTA_PROJECT=my-project

# Next.js が既定で出さないスパンも出す / 調査用
NEXT_OTEL_VERBOSE=1
OTEL_LOG_LEVEL=debug
```

サービスアカウント認証ならクォータプロジェクトは自動で決まるため
`GOOGLE_CLOUD_QUOTA_PROJECT` は設定しない（設定すると `x-goog-user-project` が付き、
`roles/serviceusage.serviceUsageConsumer` がないと 403 になる）。

## Next.js が自動で出すスパン

Next.js 本体が OpenTelemetry で計装済みなので、以下は自分で書かなくても出る。

| スパン名 | `next.span_type` | 内容 |
|---|---|---|
| `[http.method] [next.route]` | `BaseServer.handleRequest` | リクエストのルートスパン |
| `render route (app) [next.route]` | `AppRender.getBodyResult` | App Router のレンダリング |
| `executing api route (app) [next.route]` | `AppRouteRouteHandlers.runHandler` | Route Handler の実行 |
| `fetch [http.method] [http.url]` | `AppRender.fetch` | コード内の `fetch`（`NEXT_OTEL_FETCH_DISABLED=1` で無効化可） |
| `generateMetadata [next.page]` | `ResolveMetadata.generateMetadata` | メタデータ生成 |
| `resolve page components` / `resolve segment modules` / `start response` | — | 既定では出ない。`NEXT_OTEL_VERBOSE=1` で出る |

`next.route` / `next.span_type` / `next.page` / `next.rsc` が属性として付く。

## Cloud Run 固有の注意

| 項目 | 内容 |
|------|------|
| CPU スロットリング | リクエスト外で CPU が絞られると Batch プロセッサの定期 flush が走らない。`--no-cpu-throttling` を付けるか `scheduledDelayMillis` を短くする |
| SIGTERM | Cloud Run は SIGTERM 後 10 秒で強制終了する。`sdk.shutdown()` を呼ぶハンドラを必ず入れる |
| logs の monitored resource | OTLP ログは resource attribute からリソース種別を決めるため `cloud_run_revision` にはならず `generic_task` になる（`faas.name` + `faas.instance` があるため） |
| API 有効化 | `gcloud services enable telemetry.googleapis.com` |

## 必要な IAM ロール

| ロール | 用途 |
|--------|------|
| `roles/telemetry.writer` | Telemetry API へのログ・メトリクス・トレース書き込み（3 シグナルまとめて） |
| `roles/telemetry.tracesWriter` | トレースのみに絞る場合 |
| `roles/telemetry.metricsWriter` | メトリクスのみに絞る場合 |
| `roles/telemetry.logsWriter` | ログのみに絞る場合 |
| `roles/serviceusage.serviceUsageConsumer` | クォータプロジェクトに対して。`x-goog-user-project` を送る場合に必要 |
