---
source_sha256: 2fbeb86c43b9789aa21bda936feff3fd39b4035b81a06ea7f92080110e3c4ec3
title: ガイド
---
# ガイド

API リファレンス以外に CyberTrain のドキュメントが扱うすべて：ブログを一歩ずつ作るチュートリアルと、フレームワークの各分野のガイドです。

<!-- list: next-list -->
- [**チュートリアル**](tutorial.md) — ブログを一歩ずつ作る：スキャフォールド、コメント、認証、アップロード、デプロイ
- [**インストール**](install.md) — 必要なもの、`cybertrain` コマンド、Spinel とフレームワークのインストールの仕組み
- [**仕組み**](how-it-works.md) — ビルド時のコード生成、インタプリタで動くビュー、サーバー、開発ループ、Rails との違いの表
- [**モデルとデータベース**](models.md) — マイグレーション、カラムの型、クエリ、関連付け、バリデーション、暗号化されたカラム、トランザクション、Rails のデータベースの引き継ぎ
- [**リクエスト**](requests.md) — レート制限、クライアントのアドレス、パラメーター付きヘッダー、クエリ文字列とリクエストボディ
- [**設定**](configuration.md) — `config/app.rb`、環境変数、タイムゾーン
- [**バックグラウンド処理と運用**](background-and-operations.md) — ジョブクラス、再試行、`every` と `cron` のタスク、ジョブページ、`worker` と `feeds` のプロセスの役割、キャッシュストア、コンソール、バックアップ、ヘルスチェック
- [**リアルタイム**](realtime.md) — Server-Sent Events または WebSocket の上の Turbo Streams、アクション・ジョブ・フィードからのブロードキャスト、署名付きストリーム名、フィードのヘルス
- [**外向きの HTTP、WebSocket フィード、メール**](external-services.md) — ストリーミング・gzip・Server-Sent Events の `HttpClient`、タイマーと再起動の `WebSocket.subscribe`、HTML メールと `deliver_later` の `Mailer`
- [**テスト**](testing.md) — アプリのテストの書き方、外向きの呼び出し、ジョブ、CI
- [**テンプレート言語**](template-language.md) — ヘルパー、コンポーネント、フォームビルダー、`app/views/**/*.html.erb` のテンプレートが呼び出せるもの
