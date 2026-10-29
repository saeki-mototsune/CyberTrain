---
source_sha256: 6b6acef2aeb60289c1882d9a367d782f35a67a456ff5b367fbd4c7eb7a0eaade
title: ガイド
---
# ガイド

API リファレンス以外に CyberTrain のドキュメントが扱うすべて：ブログを一歩ずつ作るチュートリアルと、フレームワークの各分野のガイドです。

<!-- list: next-list -->
- [**チュートリアル**](tutorial.md) — ブログを一歩ずつ作る：スキャフォールド、コメント、認証、アップロード、デプロイ
- [**インストール**](install.md) — 必要なもの、`cybertrain` コマンド、Spinel とフレームワークのインストールの仕組み
- [**仕組み**](how-it-works.md) — ビルド時のコード生成、インタプリタで動くビュー、サーバー、開発ループ、Rails との違いの表
- [**モデルとデータベース**](models.md) — マイグレーション、`where` を超えるクエリ、ページネーション、トランザクション、カラム名、並び順
- [**リクエスト**](requests.md) — レート制限、クライアントのアドレス、パラメーター付きヘッダー、クエリ文字列とリクエストボディ
- [**設定**](configuration.md) — `config/app.rb`、環境変数、タイムゾーン
- [**バックグラウンド処理と運用**](background-and-operations.md) — ジョブ、定期タスク、バックアップ、ヘルスチェック
- [**外向きの HTTP、WebSocket フィード、メール**](external-services.md) — `HttpClient`、`WebSocket.subscribe`、`Mailer`
- [**テスト**](testing.md) — アプリのテストの書き方、外向きの呼び出し、CI
- [**テンプレート言語**](template-language.md) — ヘルパー、フォームビルダー、`app/views/**/*.html.erb` のテンプレートが呼び出せるもの
