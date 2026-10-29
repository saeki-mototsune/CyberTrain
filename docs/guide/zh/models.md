---
source_sha256: d62a91b26f80349bd7e891915008018ac461080efd3d2b307d2642cc718b3687
---
# 模型与数据库

## 迁移

位于 `db/migrate/<version>_<name>.rb` 的迁移是 `Cybertrain::Migration::Base` 的子类。它的 `change` 记录 schema 操作（`create_table`、`add_column`、`add_index`、`rename_column`、`add_reference`、`remove_column`、`remove_index`、`drop_table`）；`cybertrain db migrate` 在各自的事务中执行每个待处理的版本，并根据数据库重写 `db/schema.rb`，`cybertrain db rollback [N]` 则运行 `change` 的逆操作。当 `change` 中包含没有自动逆操作的操作时，请编写 `down`（以及 `up`）。

需要数据步骤才能安全进行的 schema 变更使用 `execute(sql, binds =
[])`。它在迁移中自己所在的位置运行，使用迁移器自己的连接，并与该版本的 schema 操作处于同一个事务中，所以在它之前添加的列在它运行时已经存在，而一旦失败，整个版本都会撤销：

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # 已有的行保持“永久”
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

不带绑定参数时，SQL 可以是多条用 `;` 分隔的语句；带绑定参数时，它是一条带 `?` 占位符的语句。`execute` 没有逆操作：回滚一个执行了 SQL 且没有自己的 `down` 的 `change` 时，会在撤销任何内容之前以 `version N is irreversible: it executes SQL in change; write down` 停止。数据语句永远不会出现在 `db/schema.rb` 中，因为它是从数据库导出的。记录迁移时不会运行任何东西，所以该语句在其版本每次 `migrate` 时恰好运行一次。

## `where` 之外的查询

生成的 relation 涵盖 `where` / `where_sql` / `order` / `limit` / `offset` / `count` / `exists?` / `delete_all`。对于大多数应用还需要的计数器、统计和搜索框，提供的是带类型的补充方法（issue #74，`docs/design.md` D22），而不是查询构建器；每个方法接收 SQL 列名，会检查并为其加引号（其他内容会引发 `ArgumentError`），并绑定每个值：

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...；返回写入的行数
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   （另有 pluck_str、pluck_float）
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # 按小时分组
Stat.where(project_id: 1).sum_int(:calls)                 # 另有 sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- `upsert` 的 `update` 值和 `count_by_sql` 的表达式都是 SQL 文本，与 `order_sql` 一样：绝不要用请求数据来构造它们。空的 `update` 相当于 `DO NOTHING`。`upsert` 和 `increment` 不加载模型，不运行验证或回调，也不填写时间戳。
- `count_by` 的键是 String（经由 `Cast.str`），按升序排列；NULL 和 `""` 共用键 `""`。带有 `limit` / `offset` 时，`count_by`、`sum_*` 和 `increment` 作用于那个窗口，与 `count` 和 `delete_all` 一样。
- `where_like` 是子串匹配（对 ASCII 不区分大小写，与 SQLite 的 LIKE 相同）。前缀搜索需要自己写模式：`Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`。
- 对于手写的 SQL，`Cybertrain::Cast.binds(a, b, c)` 构造 `execute` 所接收的绑定参数数组（Time 转为 UTC 的 ISO 8601 文本，布尔值转为 1/0）：`Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`。
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` 把解析得到的 JSON 值收窄为 Hash / Array；如果它不是，则返回一个新的空 Hash / Array（会先检查 Time，spikes/NOTES.md 规则 8）。它们返回带类型的浅拷贝，而不是 `v` 本身；`Cast.empty_hash` / `Cast.empty_array` 是预置类型的空容器。

## 分页

列表页面从 `?page=N` 读取页码，对 relation 取窗口，并渲染链接：

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

`params.page_number` 是从 1 开始的 `page` 参数，缺失或不是数字时为 1，并被限制在 `1..max_page` 范围内（`config.max_page`，默认 10000，`CYBERTRAIN_MAX_PAGE`）；它从不把长度不受限的文本交给 `String#to_i`，后者在 Spinel 下超过 2**63-1 时会抛出 `RangeError`。`params.int(:per, default: 20,
min: 1, max: 100)` 对任意键进行同样有界的读取（可选的 `-` 加上最多 18 位数字，否则取默认值；限制在 `min..max` 范围内）。`relation.page(n, per: 50)` 在 relation 上设置 `LIMIT per OFFSET (n - 1) * per`（会替换之前的 `limit`/`offset`，所以请最后调用它），以同样的方式限制 `n`，因此偏移量永远不会超过 `(max_page - 1) * per`，并返回一个 `Cybertrain::Page`：`number`、`per`、`row_offset`、`next?`（在窗口上用一条 `SELECT 1 ... LIMIT per + 1` 查询得出，不使用 `COUNT(*)`）、`prev?`、`next_number`、`prev_number`。行仍然留在 relation 上，所以 `@articles.each` 产出带类型的 `Article`；`per` 超出 1..1000 时会引发 `ArgumentError`。`paginate @page, path` 渲染 `<nav class="pager">`，其中有 “Newer” 链接（`rel="prev"`）、“Page N” 和 “Older” 链接（`rel="next"`），没有对应页面时相应的链接会省略；这些链接保留当前的查询字符串，只替换 `page`（第 1 页时去掉它），并重新编码和转义，所以搜索或筛选条件在翻页后仍然保留；而带有自己查询字符串的路径（`"/search?q=x"`）则改用它自己的查询字符串。仅支持偏移分页：适用于超大表的键集分页（`after: id`）尚未实现。脚手架生成的 index 视图会列出所有记录；加上上面三行即可对它分页。
