# telemetry.ts — 完全実装リファレンス（traces / metrics / logs）

Telemetry API (`telemetry.googleapis.com`) に **gRPC OTLP で 3 シグナルすべてを直送**する構成。

## なぜ gRPC なのか

Google は「SDK から直送する場合は gRPC exporter のみを使い、HTTP exporter は使わないこと」と明記している。
理由は HTTP exporter がヘッダーを初期化時に固定するため、アクセストークンを動的に更新できないこと。

gRPC なら CallCredentials が**リクエストごとに `authClient.getRequestHeaders()` を呼ぶ**ため、
google-auth-library 側でトークンの期限管理・更新が完結する。
自前のトークンキャッシュ・exporter 再生成ラッパーは不要。

`x-goog-user-project`（クォータプロジェクト）も `getRequestHeaders()` が付与するため、
ローカル開発の `authorized_user` 資格情報でも `GOOGLE_CLOUD_QUOTA_PROJECT` を設定するだけで通る。

## 落とし穴: `createFromGoogleCredential` は使えない

Google の公式サンプルは `credentials.createFromGoogleCredential(authClient)` を使っているが、
**google-auth-library v10 以降では認証ヘッダーが無音で落ちる。**

- grpc-js の実装は `Object.keys(headers)` でヘッダーを列挙している
- google-auth-library は v10 で `getRequestHeaders()` の戻り値を web の `Headers` に変更した
- `Object.keys(new Headers({...}))` は `[]` を返す → Metadata が空 → `UNAUTHENTICATED`

型エラーとしても出る（`Promise<Headers>` が `Promise<{[k:string]:string}>` に代入できない）ので、
`as any` で潰さないこと。`createFromMetadataGenerator` で `Headers` を自分で展開する。

## src/config/telemetry.ts

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
import type { ChannelCredentials } from '@grpc/grpc-js';

let sdk: NodeSDK | null = null;

/**
 * ADC からチャネル資格情報を作る。
 *
 * credentials.createFromGoogleCredential() は使わない（Object.keys(Headers) が空になり
 * 認証ヘッダーが無音で落ちる）。getRequestHeaders() をリクエストごとに呼ぶことで、
 * トークンの更新とクォータプロジェクトヘッダーの付与は google-auth-library に任せられる。
 */
async function createChannelCredentials(): Promise<ChannelCredentials> {
  const auth = new GoogleAuth({
    scopes: 'https://www.googleapis.com/auth/cloud-platform',
  });
  const authClient = await auth.getClient();

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

  return credentials.combineChannelCredentials(credentials.createSsl(), callCredentials);
}

export async function startTelemetry(): Promise<void> {
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.INFO);

  try {
    const channelCredentials = await createChannelCredentials();

    sdk = new NodeSDK({
      // resource: gcp.project_id が送信先プロジェクトを決める（OTEL_RESOURCE_ATTRIBUTES で渡す）
      resourceDetectors: [envDetector, hostDetector, processDetector, gcpDetector],

      // --- traces ---
      traceExporter: new OTLPTraceExporter({ credentials: channelCredentials }),
      instrumentations: [
        new HttpInstrumentation({
          ignoreIncomingRequestHook: (req) => req.url === '/health',
        }),
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

    sdk.start();
    diag.info('[OTel] SDK started');
  } catch (error) {
    // 可観測性の初期化失敗でアプリを落とさない。ただし黙って握り潰さず必ず出す
    diag.error('[OTel] failed to initialize', error);
  }
}

export async function stopTelemetry(): Promise<void> {
  if (!sdk) return;
  try {
    // shutdown() は span / metric / log すべてを flush する
    await sdk.shutdown();
    diag.info('[OTel] SDK shut down');
  } catch (error) {
    diag.error('[OTel] shutdown failed', error);
  }
}
```

`OTEL_EXPORTER_OTLP_ENDPOINT` を設定しておけば `url` の明示は不要。
`https://` スキームなので exporter は TLS 前提で解決し、コードで渡した `credentials` が優先される。
gRPC ではパス（`/v1/traces` など）は付かない — シグナルの振り分けは gRPC サービスメソッドで行われる。

## src/index.ts のエントリポイント構成

```typescript
// OpenTelemetry の初期化を最初に実行
import { startTelemetry, stopTelemetry } from './config/telemetry.js';
await startTelemetry();

import { serve } from '@hono/node-server';
import { httpInstrumentationMiddleware } from '@hono/otel';
import { Hono } from 'hono';
import myRoute from './routes/my-route.js';

const app = new Hono();

// meterProvider を渡さなければグローバルのものを使う。
// captureActiveRequests で http.server.active_requests も出る
const otelMiddleware = httpInstrumentationMiddleware({ captureActiveRequests: true });
app.use('*', (c, next) => {
  if (c.req.path === '/health') return next();
  return otelMiddleware(c, next);
});

app.route('/tools/something', myRoute);
app.get('/', (c) => c.json({ status: 'ok' }));
app.get('/health', (c) => c.json({ status: 'ok' }));

const server = serve({ fetch: app.fetch, port: Number(process.env.PORT) || 3000 }, (info) => {
  console.log(`Server is running on http://localhost:${info.port}`);
});

// SIGTERM で「接続を閉じる → テレメトリを flush」の順に落とす。
// 逆順にすると処理中リクエストのスパン・ログが失われる
const shutdown = async () => {
  server.close();
  await stopTelemetry();
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
```

ESM では static import はすべてホイストされるが、`await startTelemetry()` は `serve()` より先に評価される。
`HttpInstrumentation` による `http` モジュールのパッチは `sdk.start()` で当たるため、
サーバーが接続を受け付ける前に計装が完了している。

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

# 詰まったときの調査用
OTEL_LOG_LEVEL=debug
```

サービスアカウント認証ならクォータプロジェクトは自動で決まるため
`GOOGLE_CLOUD_QUOTA_PROJECT` は設定しない（設定すると `x-goog-user-project` が付き、
`roles/serviceusage.serviceUsageConsumer` がないと 403 になる）。

## Cloud Run 固有の注意

| 項目 | 内容 |
|------|------|
| CPU スロットリング | リクエスト外で CPU が絞られると Batch プロセッサの定期 flush が走らない。`--no-cpu-throttling` を付けるか `scheduledDelayMillis` を短くする |
| SIGTERM | Cloud Run は SIGTERM 後 10 秒で強制終了する。`sdk.shutdown()` を待つハンドラを必ず入れる |
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
