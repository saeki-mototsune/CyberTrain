---
source_sha256: 374b8ba0c4bb2332191335290295150f202b174c2aef2b9543363b27ccbeccd0
title: ガイド
---
# ガイド

API リファレンス以外に CyberTrain のドキュメントが扱うすべて：ブログを一歩ずつ作るチュートリアルと、フレームワークの各分野のガイドです。

<!-- list: next-list -->
- [**チュートリアル**](tutorial.md) — ブログを一歩ずつ作る：スキャフォールド、コメント、Turbo によるライブ更新、バックグラウンドジョブ、認証、アップロード、デプロイ
- [**インストール**](install.md) — 必要なもの、`cybertrain` コマンド、Spinel とフレームワークのインストールの仕組み
- [**仕組み**](how-it-works.md) — ビルド時のコード生成、インタプリタで動くビュー、サーバー、開発ループ、Rails との違いの表
- [**モデルとデータベース**](models.md) — マイグレーション、カラムの型、クエリ、関連付け、バリデーション、暗号化されたカラム、トランザクション、Rails のデータベースの引き継ぎ
- [**リクエスト**](requests.md) — ルーティング、フォーマットと `respond_to`、コンサーン、Strong Parameters、HTTP キャッシュ、Cookie と暗号化されたセッション、レート制限、Content Security Policy、`force_ssl` とホストの確認、ヘッダー、クエリ文字列とリクエストボディ
- [**認証**](authentication.md) — `generate authentication`：サインイン、サインアップか招待制、パスワードリセット、確認、ロックアウト、ログインしたままにする、アカウントページ、管理者ユーザー、0.4 からのアップグレード
- [**アセット**](assets.md) — ダイジェスト付きのスタイルシート、画像、JavaScript、CSS の `url()`、ヘルパー、インポートマップ、配信と保持
- [**国際化**](i18n.md) — `config/locales` の辞書、`t` と `l`、遅延ルックアップ、複数形、リクエストごとのロケールの選び方、翻訳されるバリデーションメッセージ、同梱の英語と日本語
- [**設定**](configuration.md) — `config/app.rb`、環境変数、タイムゾーン
- [**バックグラウンド処理と運用**](background-and-operations.md) — ジョブクラス、再試行、`every` と `cron` のタスク、ジョブページ、`worker` と `feeds` のプロセスの役割、キャッシュストア、コンソール、バックアップ、ヘルスチェック、ログとリクエスト ID、Sentry へのエラー報告
- [**リアルタイム**](realtime.md) — Server-Sent Events または WebSocket の上の Turbo Streams、アクション・ジョブ・フィードからのブロードキャスト、署名付きストリーム名、フィードのヘルス
- [**外向きの HTTP、WebSocket フィード、メール**](external-services.md) — ストリーミング・gzip・Server-Sent Events の `HttpClient`、タイマーと再起動の `WebSocket.subscribe`、HTML メールと `deliver_later` の `Mailer`
- [**テスト**](testing.md) — アプリのテストの書き方、外向きの呼び出し、ジョブ、ログとエラー報告、CI
- [**テンプレート言語**](template-language.md) — ヘルパー、コンポーネント、フォームビルダー、`app/views/**/*.html.erb` のテンプレートが呼び出せるもの
