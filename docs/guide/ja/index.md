---
source_sha256: dd0210788bb4d555f4969d357b102d23620f552a33d2a0ef7869ccee0a0bfce0
title: ガイド
---
# ガイド

API リファレンス以外に CyberTrain のドキュメントが扱うすべて：ブログを一歩ずつ作るチュートリアルと、フレームワークの各分野のガイドです。

<!-- list: next-list -->
- [**チュートリアル**](tutorial.md) — ブログを一歩ずつ作る：スキャフォールド、コメント、認証、アップロード、デプロイ
- [**インストール**](install.md) — 必要なもの、`cybertrain` コマンド、Spinel とフレームワークのインストールの仕組み
- [**仕組み**](how-it-works.md) — ビルド時のコード生成、インタプリタで動くビュー、サーバー、開発ループ、Rails との違いの完全な一覧
- [**モデルとデータベース**](models.md) — マイグレーション、`where` を超えるクエリ、ページネーション
- [**リクエスト**](requests.md) — レート制限、クライアントのアドレス、パラメーター付きヘッダー、クエリ文字列とリクエストボディ
- [**設定**](configuration.md) — `config/app.rb`、環境変数、タイムゾーン
- [**バックグラウンド処理と運用**](background-and-operations.md) — ジョブ、定期タスク、バックアップ、ヘルスチェック
- [**外向きの HTTP、WebSocket フィード、メール**](external-services.md) — `HttpClient`、`WebSocket.subscribe`、`Mailer`
- [**テスト**](testing.md) — アプリのテストの書き方、外向きの呼び出し、CI
- [**テンプレート言語**](template-language.md) — ヘルパー、フォームビルダー、`app/views/**/*.html.erb` のテンプレートが呼び出せるもの
