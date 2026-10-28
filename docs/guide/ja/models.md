---
source_sha256: d62a91b26f80349bd7e891915008018ac461080efd3d2b307d2642cc718b3687
---
# モデルとデータベース

## マイグレーション

`db/migrate/<version>_<name>.rb` のマイグレーションは `Cybertrain::Migration::Base` のサブクラスです。その `change` はスキーマの操作（`create_table`、`add_column`、`add_index`、`rename_column`、`add_reference`、`remove_column`、`remove_index`、`drop_table`）を記録します。`cybertrain db migrate` は未適用の各バージョンをそれぞれのトランザクションで適用し、データベースから `db/schema.rb` を書き直します。`cybertrain db rollback [N]` は `change` の逆を実行します。自動的な逆操作のない操作を `change` が含む場合は、`down`（と `up`）を書いてください。

安全に行うためにデータの手順を必要とするスキーマの変更には、`execute(sql, binds =
[])` を使います。これはマイグレーション内の書かれた位置で、マイグレーター自身の接続で、そのバージョンのスキーマ操作と同じトランザクションの中で実行されます。そのため、その前に追加したカラムは実行時には存在しており、失敗するとバージョン全体が取り消されます：

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # 既存の行は「無期限」のまま
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

バインドがない場合、SQL は `;` で区切った複数の文でもかまいません。バインドがある場合は、`?` プレースホルダーを持つ 1 つの文です。`execute` には逆操作がありません：SQL を実行する `change` を、独自の `down` なしでロールバックしようとすると、何かを元に戻す前に `version N is irreversible: it executes SQL in change; write down` で停止します。データの文が `db/schema.rb` に現れることはありません。このファイルはデータベースからダンプされるためです。マイグレーションの記録時には何も実行されないので、文はそのバージョンの `migrate` ごとにちょうど 1 回実行されます。

## `where` を超えるクエリ

生成されるリレーションは `where` / `where_sql` / `order` / `limit` /
`offset` / `count` / `exists?` / `delete_all` を扱います。ほとんどのアプリケーションが必要とするカウンター、統計、検索ボックスのために、クエリビルダーではなく型付きの追加機能があります（issue #74、`docs/design.md` D22）。どれも SQL のカラム名を受け取り、検査してクォートし（それ以外は `ArgumentError`）、すべての値をバインドします：

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; 書き込んだ行数を返す
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   （pluck_str、pluck_float もある）
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # 1 時間ごとの集計
Stat.where(project_id: 1).sum_int(:calls)                 # sum_float もある
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- `upsert` の `update` の値と `count_by_sql` の式は、`order_sql` と同じく SQL テキストです：決してリクエストのデータから組み立てないでください。空の `update` は `DO NOTHING` です。`upsert` と `increment` はモデルを読み込まず、バリデーションもコールバックも実行せず、タイムスタンプも埋めません。
- `count_by` のキーは String（`Cast.str` を通したもの）で、昇順です。NULL と `""` はキー `""` を共有します。`limit` / `offset` がある場合、`count_by`、`sum_*`、`increment` は、`count` や `delete_all` と同じく、その範囲に対して働きます。
- `where_like` は部分文字列の一致です（SQLite の LIKE と同じく、ASCII については大文字小文字を区別しません）。前方一致の検索では自分でパターンを書きます：`Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`。
- 手書きの SQL には、`Cybertrain::Cast.binds(a, b, c)` が `execute` の受け取るバインドの Array を組み立てます（Time は UTC の ISO 8601 テキスト、真偽値は 1/0）：`Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`。
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` は、パースした JSON の値を Hash / Array に絞り込みます。そうでない場合は新しい空のものを返します（Time を最初に確認します。spikes/NOTES.md のルール 8）。返すのは `v` そのものではなく、型付きの浅いコピーです。`Cast.empty_hash` / `Cast.empty_array` は、型の種となる空のコンテナーです。

## ページネーション

一覧ページは `?page=N` からページ番号を読み、リレーションの範囲を絞り、リンクをレンダリングします：

```ruby
# app/controllers/articles_controller.rb
def index
  @articles = Article.all.order("created_at DESC")
  @page = @articles.page(params.page_number, per: 20)
end
```

```erb
<%# app/views/articles/index.html.erb %>
<% @articles.each do |article| %>
  <p><%= link_to article.title, article %></p>
<% end %>
<%= paginate @page, articles_path %>
```

`params.page_number` は 1 から始まる `page` パラメーターです。ない場合や数値でない場合は 1 で、`1..max_page`（`config.max_page`。デフォルトは 10000、`CYBERTRAIN_MAX_PAGE`）に収められます。上限のないテキストを `String#to_i` に渡すことは決してありません。Spinel では 2**63-1 を超えると `RangeError` を出すためです。`params.int(:per, default: 20,
min: 1, max: 100)` は、任意のキーに対する同じ上限付きの読み取りです（省略可能な `-` と最大 18 桁の数字。それ以外はデフォルト値。`min..max` に収められます）。`relation.page(n, per: 50)` はリレーションに `LIMIT per OFFSET (n - 1) * per` を設定し（それ以前の `limit`/`offset` を置き換えるので、最後に呼んでください）、`n` を同じ方法で収めるので、オフセットが `(max_page - 1) * per` を超えることはありません。そして `Cybertrain::Page` を返します：`number`、`per`、`row_offset`、`next?`（範囲に対する 1 回の `SELECT 1 ... LIMIT per + 1` で問い合わせ、`COUNT(*)` は使いません）、`prev?`、`next_number`、`prev_number`。行はリレーションに残るので、`@articles.each` は型付きの `Article` を渡します。1..1000 の範囲外の `per` は `ArgumentError` です。`paginate @page, path` は `<nav class="pager">` をレンダリングし、「Newer」のリンク（`rel="prev"`）、「Page N」、「Older」のリンク（`rel="next"`）を含めます。該当するページがなければ、それぞれ省かれます。リンクは現在のクエリ文字列を保ったまま `page` を置き換え（1 ページ目では取り除きます）、再エンコードしてエスケープするので、検索やフィルターはページをめくっても残ります。独自のクエリ文字列を持つパス（`"/search?q=x"`）では、代わりにそちらを使います。オフセットによるページネーションのみです：非常に大きなテーブル向けのキーセットページネーション（`after: id`）はまだ作られていません。スキャフォールドの index ビューはすべてのレコードを一覧します。ページ分けするには上の 3 行を追加してください。
