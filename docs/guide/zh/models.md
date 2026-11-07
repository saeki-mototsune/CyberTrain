---
source_sha256: 1b75a8cb6cc5f39be25f87f30bbbb124f8c6543bfdbdca023f225a1aa2f13404
---
# 模型与数据库

模型在脚手架之外还能做什么：迁移、列类型、查询、关联、校验、加密列、分页、事务、在 Spinel 下列名和 `order` 子句所遵循的规则，以及接管 Rails 创建的数据库。

## 迁移

位于 `db/migrate/<version>_<name>.rb` 的迁移是 `Cybertrain::Migration::Base` 的子类。它的 `change` 记录 schema 操作（`create_table`、`add_column`、`add_index`、`rename_column`、`add_reference`、`remove_column`、`remove_index`、`drop_table`，以及[修改表](#changing-a-table)中的操作）；`cybertrain db migrate` 在各自的事务中执行每个待处理的版本，并根据数据库重写 `db/schema.rb`，`cybertrain db rollback [N]` 则运行 `change` 的逆操作。当 `change` 中包含没有自动逆操作的操作时，请编写 `down`（以及 `up`）。

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

### 索引与外键

`add_index` 接受 `where:` 来建部分索引；`t.references` 接受 `on_delete:` 和 `index: false`，`add_reference` 接受 `on_delete:` 并且总会添加索引：

```ruby
create_table "comments" do |t|
  t.references :article, on_delete: :cascade   # ON DELETE CASCADE
  t.references :author, null: true, on_delete: :nullify, index: false
  t.text "body"
  t.timestamps
end
add_index "comments", ["body"], where: "body IS NOT NULL"
```

`on_delete:` 取 `:cascade`、`:nullify`（该列必须允许 NULL）或 `:restrict`；默认不写 `ON DELETE` 子句（即 SQLite 的 `NO ACTION`）。选哪一个见 [`dependent:` 还是 `on_delete:`](#dependent-or-on_delete)。表达式索引（`LOWER(email)`）没有迁移辅助方法：用 `execute "CREATE UNIQUE INDEX index_users_on_lower_email ON users (LOWER(email))"` 创建。`db/schema.rb` 会把它导出为 `s.add_index "users", "LOWER(email)", unique: true, name: "index_users_on_lower_email"`，部分索引的 `where:` 也会保留在导出中。

### 修改表

```ruby
class TidyPosts < Cybertrain::Migration::Base
  def up
    rename_table :posts, :articles
    change_column :articles, :views, :bigint, null: false, default: "0"
    change_column_default :articles, :state, from: nil, to: "'draft'"
    change_column_null :articles, :title, false, "untitled"
    remove_reference :articles, :legacy_owner
    remove_foreign_key :articles, :authors
  end

  def down
    # write the reverse of each step
  end
end
```

- `rename_table` 是 `ALTER TABLE ... RENAME TO`，指向该表的外键会跟着改。它的索引保留原名（Rails 会按新表名重命名）。
- 其余五个会重建表，因为 SQLite 没有 `ALTER COLUMN`：按修改后的定义新建一张表，复制各行，删除旧表并重命名新表，再恢复它的索引、触发器和 `AUTOINCREMENT` 的最高值。其他表中引用它的视图和触发器照常工作。
- `change_column` 重新声明该列：没有传入的选项（默认值、`null: false`）会像 Rails 一样消失。
- `change_column_default` 需要 `to:`（SQL 字面量文本，`nil` 表示去掉默认值）；`from:` 指明之前的默认值，使其可以回滚。
- `change_column_null` 的第四个参数是加上 `NOT NULL` 之前写入 NULL 单元格的值；它不会成为该列的默认值。
- `remove_foreign_key :articles, :authors` 删除外键，保留该列及其索引（列名不是 `author_id` 时用 `column:` 指定）。

`rename_table`，以及带 `from:` 的 `change_column_default`，在 `change` 中会自动反转；`change_column_null` 也是如此，只是回滚 `null: true` 时需要第四个参数来填充之后变成 NULL 的单元格。`change_column`、`remove_reference` 和 `remove_foreign_key` 在 `change` 中不可逆：请编写 `up` 和 `down`。

<details><summary>重建会拒绝什么，以及重建期间的外键 — CHECK、COLLATE、生成列等</summary>

重建按 `db/schema.rb` 能表达的内容来声明表。在动表之前，它会读取该表的 `CREATE TABLE` 文本，若其中有 schema 无法表达的内容就拒绝（`rebuilding posts would drop a CHECK constraint: rewrite the migration with execute`），该版本随之回滚。这包括 `CHECK` 约束或行内 `UNIQUE` 约束（唯一索引没问题）、`COLLATE`、生成列、`ON UPDATE`、`ON DELETE SET DEFAULT`、`DEFERRABLE`、指向 `id` 以外列的外键、没有类型的列、`id` 以外的主键，以及 `WITHOUT ROWID` 或 `STRICT` 表。这项检查是在 SQL 文本中查找这些词，而不是解析器：重建手写的表之前，请先读一读导出的 schema。普通的 `id INTEGER PRIMARY KEY` 重建后会带上 `AUTOINCREMENT`，所有行和 id 都会保留。类型的确切写法会被规范化（`datetime(6)` 变为 `DATETIME`）。

包含重建的版本在关闭 `PRAGMA foreign_keys` 的情况下运行（在事务内无法关闭，所以由迁移器在版本前后切换），并在提交前运行 `PRAGMA foreign_key_check`：一旦有违反，该版本回滚并列出相关行。检查覆盖整个数据库，所以别的表中早已存在的违反也会让该版本停下，这与 Rails 相同。

</details>

### 双向的数据步骤：`reversible`

```ruby
class BackfillSlugs < Cybertrain::Migration::Base
  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = lower(title)" }
      dir.down { execute "UPDATE posts SET slug = NULL" }
    end
  end
end
```

`dir.up` 的语句在迁移时运行，`dir.down` 的语句在回滚时运行，各自按书写顺序执行。块内只能写 `execute`。不提供：`create_join_table`、`change_table`、`rename_index`、`add_timestamps`。

`cybertrain db status` 列出每个版本；在 `schema_migrations` 中但 `db/migrate` 下没有文件的版本（由别的工具迁移的数据库）显示为 `applied (no file)`，迁移器既不运行也不回滚它。`cybertrain db schema` 不做迁移，直接根据数据库写出 `db/schema.rb`（[接管 Rails 创建的数据库](#taking-over-a-database-rails-created)）。

## 列类型

| Schema DSL | SQL | Ruby 属性 |
| --- | --- | --- |
| `t.string`, `t.text` | `VARCHAR(n)` / `VARCHAR`, `TEXT` | String |
| `t.integer`, `t.bigint`, `t.references` | `INTEGER`, `BIGINT` | Integer |
| `t.float` | `FLOAT` | Float |
| `t.decimal :price, precision: 18, scale: 8` | `DECIMAL(18,8)` | Float，存储时按 scale 舍入 |
| `t.boolean` | `BOOLEAN` | true / false |
| `t.datetime` | `DATETIME` | Time（UTC，微秒） |
| `t.date` | `DATE` | Date |
| `t.json :meta, default: "{}"` | `JSON` | 以 String 为键的 Hash |
| `t.binary` | `BLOB` | 字节组成的 String（[二进制列](#binary-columns)） |

允许 NULL 的列，其属性也可以是 nil。`new`、`update` 和 `write_attribute` 会转换传入的值（整数列中的 `"42"` 变成 `42`，日期列中的 `"2026-10-05"` 变成 Date）；直接的 writer `post.price = ...` 不转换。SQLite 的 INTEGER 是 64 位的，所以 `t.bigint` 只是换了名字的整数列。`t.datetime :x, precision: 6` 可以接受；每个 datetime 都保留微秒。

### decimal 是 Float

Rails 把 `decimal` 列读成 BigDecimal；这里它是 Float，生成的模型每次存储时（`save`、`update_columns`、`update_all`、批量写入）都会按该列的 `scale:` 舍入，所以存下的就是 Rails 赋值之后会存的值。Spinel 的 BigDecimal 目前还不能由 Float 或 String 构造，也不能舍入，这就是重新考虑的条件（`docs/design.md` D42）。二进制浮点数在长的求和中会累积误差：在边界处舍入（`total.round(2)`），或者把金额以最小单位存在整数列中（`price_cents`）。

### JSON 列

`json` 列保存一个对象，读作 `Hash`（文本不是 JSON 对象时，NOT NULL 列为 `{}`，可为 NULL 的列为 nil），用 `JSON.generate` 写入。它的值和 Spinel 下所有解析出的 JSON 值一样是装箱的，所以要通过 `Cybertrain::Cast` 读取：

```ruby
event.meta = { "attempts" => 2, "tags" => ["a", "b"] }
event.save
Cybertrain::Cast.int(event.meta["attempts"])   # => 2
Cybertrain::Cast.array(event.meta["tags"])     # => ["a", "b"]
```

赋入不合法的 JSON 文本会变成 `{}`。不支持以 Array 为根：把它存在 `text` 列中，用 `Cast.array` 读取。对 json 列用 `where` 会抛出 `ArgumentError`，`pluck` 返回存储的文本。

### 日期时间与 `db normalize`

datetime 按 Rails 在 SQLite 中的存法存储，即 `2026-10-05 09:00:00.000000`（UTC、一个空格、六位小数），读取时接受 `T` 或空格、任意位数的小数，以及 `Z` 或时区偏移。JSON（`as_json`、`to_json`）写出 Rails 的显示形式 `2026-10-05T09:00:00.000Z`。在手写 SQL 中，`Cybertrain::Cast.sql_datetime(time)` 给出存储文本，`Cast.iso8601(time)` 给出显示文本。

CyberTrain 0.4 存的是 `2026-10-05T09:00:00Z`，无论日期如何，它都排在所有 Rails 格式的值之后。升级之后运行一次，重写旧单元格：

```console
$ cybertrain db normalize
normalized articles.created_at: 12 rows (0 unreadable left alone)
normalized articles.updated_at: 12 rows (0 unreadable left alone)
done
```

它在一个事务中逐行重写每张表每个 `DATETIME` 列（包括 `datetime(6)`）中尚不是存储格式的单元格，运行两次也安全。无法读成时间的单元格（带有 ` UTC` 这类多余文本）保持不变并计数。`WITHOUT ROWID` 表，以及有名为 `_rowid_` 的列的表，会被跳过；如果其中仍有旧单元格，命令会打印 `skipped t.c: without rowid (N rows still need normalization)`（或 `declares _rowid_`）并以 1 退出：请手工更新这些行后再运行一次。它需要 SQLite 3.37.0 或更新版本：CyberTrain 链接系统的 libsqlite3（`sqlite3 --version` 可查看），版本更旧时命令会在读取任何内容之前以 `db normalize failed: ...` 停止。在生产环境中，在 `migrate` 和启动新二进制之间运行 `./<app> db normalize`（[部署升级](../deploy.en.md#upgrading-the-framework)）。

### 日期

`date` 列是 `Date`（`Date.new(2026, 10, 5)`），存为 `2026-10-05`；`where(day: date)` 以该文本绑定。赋入的文本必须是 `YYYY-MM-DD`：其他内容（或空白）读回为 nil。NOT NULL 的日期列会得到生成的存在性校验，所以 `save` 会返回 false 并给出 “can't be blank”，而不是由数据库拒绝该行；有默认值的列从默认值开始。`Cybertrain::Cast.date_or_nil(params[:from])` 以同样方式读取日期参数。

### 解析时间

`Time.iso8601(text)`、`Time.rfc2822(text)` 和 `Time.strptime(text, format)` 以 Ruby 的名字提供，遇到无法读取的文本都会抛出 `ArgumentError`。`strptime` 接受 `%Y %m %d %H %M %S %L %z %Z %b %B %a %A %j %s %%`（`%Z` 只接受 `UTC`、`GMT` 或 `Z`）。`Time.at(ms / 1000.0)` 把毫秒纪元转成 Time。

## 条件与查找

生成的 relation 的查询方法也都是类方法（除了 `or`、`not`、`page`、`to_sql`，以及类似 Array 的 `to_a`、`each`、`size`、`empty?`），所以 Rails 的写法照样可用：`Article.where.not(body: nil)`、`Article.find_each { }`、`Article.pluck(:id, :title)`、`Article.pluck_int(:id)`。

| Rails | CyberTrain |
| --- | --- |
| `where(views: 1..10)`, `where(views: 10..)` | 相同，仅限 Integer 端点 |
| `where(created_at: from..to)` | `where_between(:created_at, from, to)`（`...` 用 `exclude_end: true`；开放端用 nil） |
| `where("views > ?", 10)` | 相同 |
| `where.not(state: "draft")`, `a.or(b)` | 相同 |
| `order(created_at: :desc)` | 相同 |
| `distinct`, `none`, `ids` | 相同 |
| `find_by!`, `find_or_create_by`, `find_or_initialize_by` | 相同 |
| `update_all`, `destroy_all`, `find_each(batch_size: 500)` | `update_all`, `destroy_all`, `find_each(batch: 500)` |
| `create!`, `record.update_columns(views: 0)` | 相同 |

- `where` 的 Hash 中的 Range 只接受 Integer 端点：在 Spinel 下无法构造 Time 或 Date 的 Range，Float 或 String 的 Range 也不会被识别为 Range，所以这些边界走 `where_between`，其 Time 和 Date 边界按存储文本比较（文本的顺序与时刻的顺序一致）。
- String 条件会被加上括弧，所以其中的 `OR` 不会外溢。它的绑定值是标量：`where("id IN (?)", ids)` 会抛出异常；请写 `where(id: ids)`。
- `a.or(b)` 是 `((a) OR (b))`；两者的排序、limit、offset 和 `distinct` 必须一致。
- 对 json 列或加密列用 `where` 会抛出 `ArgumentError`。
- `distinct` 让读取列的方法对每个值只返回一次，并让聚合读取去重后的输入（`SUM(DISTINCT x)`）；`count` 和 `to_a` 不变，因为每行都有自己的 id。
- `update_all(hash)` 像 `save` 存储时那样转换和舍入，不改 `updated_at`，也不运行回调；`destroy_all` 逐条销毁记录，包括回调和 `dependent:`。
- `find_each` 按 id 分批遍历，并像 Rails 一样忽略 relation 的排序、limit 和 offset。
- 在收窄过的 relation 上，`find_or_create_by` 只用传给它的 Hash 创建记录；Rails 还会带上 relation 的相等条件。请传入新记录所需的全部属性。
- `update_columns` 先赋值，再对这些列执行一次 UPDATE：不校验、不回调，`updated_at` 不变。

## Scope

```ruby
# app/models/article.rb
class Article
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where("created_at > ?", time) }
end

Article.recent.since(Time.now - 86_400).limit(5).to_a
```

生成器把每一行 `scope` 当作文本读取，把 lambda 的参数和主体复制到模型 relation 的一个方法（`def since(time) = (where("created_at > ?", time))`）以及委托给它的类方法中，所以 scope 可以像任何查询一样串联。生成时不求值任何东西：主体中引用了 relation 没有的东西时，会在 Spinel 编译 `gen/models` 时、在生成的那一行失败。

scope 是类层级的一行：一个 `->` lambda，带普通的或有默认值的位置参数，结尾的 `}` 之后什么都不能有（注释也不行），默认值中不能有括号或逗号。与列、另一个 scope、查询方法（`where`、`count`、`first`）或 `Object` 的方法（`hash`、`then`、`raise`）同名的 scope 会让生成器停下，并给出文件、行号和原因。

## `where` 之外的查询

除了上面的条件，大多数应用需要的计数器、统计和搜索框都以带类型的方法提供（`docs/design.md` D22、D44、D45），而不是查询构建器；每个方法都接受 SQL 列名，经过检查并加引号（其他内容都是 `ArgumentError`），并绑定每一个值：

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...；返回写入的行数
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1 (by: n for another step)
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   （另有 pluck_str、pluck_float）
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # 按小时分组
Stat.where(project_id: 1).sum_int(:calls)                 # 另有 sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- 每个方法都带类型，因为 Spinel 的方法只有一种返回类型：`pluck_str` / `pluck_int` / `pluck_float` 只读取一列，`sum_int` / `sum_float` 只对一列求和，`count_by` 返回 `Hash{String => Integer}`。
- `upsert` 的 `update` 值和 `count_by_sql` 的表达式都是 SQL 文本，与 `order_sql` 一样：绝不要用请求数据来构造它们。空的 `update` 相当于 `DO NOTHING`。`upsert` 和 `increment` 不加载模型，不运行验证或回调，也不填写时间戳。
- `count_by` 的键是 String（经由 `Cast.str`），按升序排列；NULL 和 `""` 共用键 `""`。带有 `limit` / `offset` 时，`count_by`、`sum_*` 和 `increment` 作用于那个窗口，与 `count` 和 `delete_all`（通过子查询）一样。
- `where_like` 会替你转义文本中的 `\`、`%` 和 `_`，并且是子串匹配（对 ASCII 不区分大小写，与 SQLite 的 LIKE 相同）。前缀搜索需要自己写模式：`Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`。
- 对于手写的 SQL，`Cybertrain::Cast.binds(a, b, c)` 会构造 `execute` 所需的绑定 Array（Time 用存储的 datetime 格式，Date 用 `YYYY-MM-DD`，布尔值为 1/0）：`Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`。
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` 把解析得到的 JSON 值收窄为 Hash / Array；如果它不是，则返回一个新的空 Hash / Array（会先检查 Time，spikes/NOTES.md 规则 8）。它们返回带类型的浅拷贝，而不是 `v` 本身；`Cast.empty_hash` / `Cast.empty_array` 是预置类型的空容器。

### 多列：`pluck` 与 `pick`

```ruby
Reading.order(:id).pluck(:observed_at, :value)   # => [[2026-10-01 09:00:00 UTC, 1.0], ...]
Reading.order(:id).pick(:id, :value)             # => [1, 1.0], or nil
```

`pluck` 接受两列或更多列，每行返回一个 Array，每个单元格按其列的类型转换：Integer、Float（float 和 decimal）、`true` / `false`、UTC 的 Time、Date、String（string、text、json 和 binary 列返回存储的文本或字节；加密列返回密文），或 nil。只给一列会抛出 `ArgumentError`，并指向 `pluck_str` / `pluck_int` / `pluck_float` / `ids`：Rails 对一列返回扁平的 Array，对多列返回嵌套的 Array，而一个方法无法两者都返回。`pick` 是第一行（`LIMIT 1`）或 nil。只接受列名；表达式走 `DB.with`。

### 聚合

| Rails | CyberTrain |
| --- | --- |
| `minimum(:views)`, `maximum(:views)` | `minimum_int`, `maximum_int`（`Integer` 或 nil） |
| 对 float 或 decimal 的 `maximum(:price)` | `minimum_float`, `maximum_float` |
| `maximum(:created_at)` | `minimum_time`, `maximum_time`（UTC 的 Time 或 nil） |
| `average(:value)` | `average(:value)`（Float 或 nil） |
| `group(:kind).sum(:value)` | `sum_float_by(:kind, :value)`（还有 `sum_int_by`） |
| `group(:kind).maximum(:created_at)` | `maximum_time_by(:kind, :created_at)`，上面每个方法都有 `_by` 形式 |
| `sum("price * quantity")` | `sum_float_sql("price * quantity")`，还有 `minimum_float_sql`、`maximum_float_sql`、`average_sql` |
| `group(:kind).having("SUM(value) > ?", 2)` | `having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value)` |

- 名字带上类型，原因与 `pluck_int` 相同：Rails 的 `maximum` 对一列返回 Integer，对另一列返回 Time。
- `_by` 方法返回 `Hash{String => T}`，键是分组列的值的文本，按升序排列，与 `count_by` 相同；NULL 和 `""` 共用键 `""`。
- `having_sql` 作用于分组方法；带有它的 relation 调用任何其他读取方法都会抛出异常，带 limit 或 offset 的分组方法也一样。
- `_sql` 表达式和 `having_sql` 是可信的 SQL，与 `order_sql` 相同。
- 在 `distinct` 下，聚合读取去重后的输入（`AVG(DISTINCT x)`）；若同时有 limit，窗口就是前 n 个不同的值。
- 同时涉及表达式*和*分组，或涉及两张表的聚合，用 `DB.with` 编写。

## 批量写入

```ruby
Article.insert_all([{ title: "One", body: "..." }, { title: "Two", body: "..." }]).size  # => 2
Article.insert_all!(rows)                                 # a duplicate raises
Article.upsert_all([{ id: 1, title: "Renamed" }])         # body keeps its value
Article.upsert_all(rows, unique_by: [:slug], update_only: [:title], returning: [:id, :title])
```

`insert_all` 用带 `ON CONFLICT DO NOTHING` 的多行 `INSERT` 语句写入大量行，跳过与已有行冲突的行；`insert_all!` 则改为抛出异常；`upsert_all` 用 `ON CONFLICT (unique_by) DO UPDATE` 更新冲突的行。结果是 `RETURNING` 的各行（默认为 `[{"id" => 3}, ...]`），按类型转换，所以 `.size` 就是写入的行数。

- 每行的键都相同，否则在写入任何内容之前就是 `ArgumentError`；未知的列同样抛出异常。没有任何行提到的列取表的 DEFAULT。
- 值经过与 `save` 相同的转换（Time 用存储格式，Hash 转成 JSON，decimal 按其 scale 舍入，Date 转成文本）。
- `upsert_all` 更新各行提供的列，但不包括 `id`、`unique_by` 的列和 `created_at`；`update_only:` 缩小这个列表，其中有但各行没有提供的名字会被跳过。
- 当表有 `created_at` / `updated_at` 而各行没有给出时，整个调用共用一个 `now`，除非 `record_timestamps: false`。
- 语句按 SQLite 的绑定上限切分，并在一个事务中运行（若已有打开的事务则加入其中），所以失败时这次调用不会留下任何内容。
- 不运行校验、回调或加密：行中有加密列会抛出 `ArgumentError`。与 Rails 一样，跳过的重复行仍会消耗一个 id。
- `RETURNING` 需要 SQLite 3.35.0 或更新版本（CyberTrain 链接的系统库）；更旧的版本会以其自身的语法错误拒绝该语句（`Cybertrain::DB::Error`）。

## 关联

外键无需一行代码就能让两边都有关联（`t.references :article` 会产生 `Comment#article` 和 `Article#comments`）。模型文件也可以声明它们，用来改名或添加选项：

```ruby
# app/models/article.rb
class Article
  has_many :comments, dependent: :destroy
  has_one :cover, class_name: "Image", foreign_key: :article_id
end

# app/models/comment.rb
class Comment
  belongs_to :article
  belongs_to :author, class_name: "User", optional: true, counter_cache: true
end
```

- `has_many` 返回子记录的 relation，因此可以串联：`@article.comments.where(approved: true).count`、`@article.comments.find(params[:id])`。需要 Array 时加 `.to_a`；模板会把它当作 Array 迭代。
- `has_one` 读取一个子记录（有多个时取 id 最小的），没有时为 nil；它取代外键本来会产生的 `has_many`。
- `belongs_to` 读取父记录并记住它，直到外键改变或 `reload`。
- 没有 `optional: true` 的已声明 `belongs_to`，在其键为 nil、空白或 0 时让记录无效（`article_id` 上的 “can't be blank”，即生成的 `validates_foreign_key :article_id`），所以 `save` 会在数据库拒绝该行之前返回 false。仅来自外键的关联不添加校验。
- 选项都是字面量：`class_name:`（String 或 Symbol）、`foreign_key:`、`dependent:`（`has_many` 和 `has_one`）、`optional:` 和 `counter_cache:`（`belongs_to`）。每个宏独占一行，写在类层级，行尾不带注释；不存在的模型、列或选项会让生成器停下，并给出文件和行号。
- 不提供：`has_many :through`、多态关联、`has_many` 上的 scope lambda（请在它返回的 relation 上串联）、`inverse_of`、`dependent: :restrict_with_error`。

### `dependent:` 还是 `on_delete:`

`dependent:` 在 `destroy` 内、父记录的 DELETE 之前、同一个事务中运行：`:destroy` 逐个加载子记录并销毁（它们的回调和自己的 `dependent:` 都会运行），`:delete_all` 执行一次 DELETE，`:nullify` 执行一次把键设为 NULL 的 UPDATE。外键上的 `on_delete:`（[索引与外键](#indexes-and-foreign-keys)）交给 SQLite 处理，无论是谁删除了这一行。子记录有回调、计数器或自己的子记录时用 `dependent: :destroy`；追求速度，或有其他程序也写这个数据库时，用 `on_delete: :cascade`。两者都没有时，外键会拒绝删除仍有子记录的父记录。

### 计数器缓存

`belongs_to :post, counter_cache: true` 让 `posts.comments_count`（或 `<has_many 的名字>_count`）保持同步：创建子记录后 +1，销毁后 -1，子记录换到另一个父记录时两边都更新，每次变化都在子记录自己的事务中。该列必须存在（`default: "0"` 的整数）。父记录自己的 `save` 不会把它放进 UPDATE，因为它的副本可能已过时。以 `dependent: :destroy` 销毁的父记录在消失前会按子记录数给自己减一次，这没有害处。

### 用 `includes` 预加载

```ruby
@articles = Article.recent.includes(:comments).to_a   # two queries
```

```erb
<% @articles.each do |article| %>
  <%= article.title %> (<%= article.comments.size %>)
<% end %>
```

`includes(*names)`（以及等同的 `preload`）在加载记录时为每个关联多执行一次查询（`has_many` 或 `has_one` 为 `Comment.where(article_id: ids)`，`belongs_to` 为按 id 查父记录），所以遍历 `article.comments` 或 `comment.article` 的循环自己不执行查询。没有子记录的记录得到空列表，缺失的父记录为 nil，不再查询。在预加载过的 `has_many` 上，`to_a`、`each`、`first`、`last`、`size` 和 `empty?` 直接从内存作答（子记录按 id 排序）；`count` 和 `exists?` 仍然查询，串联方法（`where`、`order` 等）会丢弃预加载，照常查询。只支持一层（没有 `includes(comments: :author)`），预加载的子记录不会设置其父记录（`comment.article` 会去读取）。不提供 `eager_load` 和 `joins`。

## 校验

```ruby
class Article
  validates :title, presence: true, length: { minimum: 3, maximum: 120 }, uniqueness: true
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create
  validates :summary, presence: true, if: :published?

  def published? = state == "published"
end
```

消息是 Rails 的英文默认值：“can't be blank”、“is too short (minimum is 3 characters)”、“is the wrong length (should be 5 characters)”、“is not included in the list”、“is reserved”、“is invalid”、“is not a number”、“must be an integer”、“must be greater than or equal to 0”、“has already been taken”。`message:` 可在行上或规则的 Hash 中替换消息。没有 Rails 的单数形式（“1 character”）：上限为 1 时显示 “1 characters”。

- `length` 接受 `minimum`、`maximum`、`is` 和 `in`（Integer 的 Range）。
- `inclusion` 和 `exclusion` 接受 Array 或 Integer 的 Range（Spinel 无法构造其他 Range）。
- `numericality` 先解析 String（`"12"` 通过）；Float 不通过 `only_integer`，与 Rails 相同。
- `uniqueness` 向数据库查询是否有另一行具有该值（`case_sensitive: false` 时为 `LOWER(col) = LOWER(?)`，nil 时为 `IS NULL`），并按 `scope:` 限定范围。不能用于加密列。
- `allow_nil:` 和 `allow_blank:` 对其所在行的每条规则（包括 `presence`）跳过 nil 或空白值；`on: :create` 或 `on: :update`（一个 Symbol）只对新记录或已保存的记录运行该行。
- 未知选项或类型不对的值会在模型加载时抛出 `ArgumentError`。

### 自定义校验与条件

```ruby
class Booking
  validate :ends_after_start, on: :update, unless: :imported?

  def ends_after_start
    errors.add(:ends_on, "must be after the start") if ends_on < starts_on
  end

  def imported? = source == "import"
end
```

`validate :method` 行在 `validates` 规则之后按顺序运行。`if:` 和 `unless:`（两种行都可用）接受一个 Symbol，指向模型的方法、列或关联；由于 Spinel 没有 `send`，生成器会写出调用它的表。lambda、`:if => :x` 和 `"if": :x` 会让生成器停下，并提示改为指定方法名；模型文件中未定义的 `validate` 名字也一样。不提供 `validates_with`、`validates_each`、`confirmation`、`acceptance` 和 `valid?(context)`。

## 加密列

```ruby
# app/models/account.rb
class Account
  encrypts :api_key
end
```

`encrypts` 指定 string 或 text 列（text 更合适：存储的密文比文本长）。生成的模型在写入行时加密该值，读取时解密，所以 `account.api_key` 是明文，而表中存的是 `1:` 后接随机 nonce、AES-256-GCM 密文及其标签的 Base64。同一个值保存两次会得到不同的密文，因此该列无法搜索：

- `where`、`where_like`、`where_between`、`update_all`、`uniqueness` 和批量写入都会拒绝它（`ArgumentError`）；`pluck` 返回密文。
- `to_json` 和 `as_json` 包含解密后的文本，与 Rails 相同；不要把这一列放进页面输出的内容。
- 存储的空值读作 `""`，所以用 `default: "''"` 添加的 NOT NULL 列在其各行重新保存之前也能读取。
- 不提供：`deterministic: true`，以及读取 Rails 的 `ActiveRecord::Encryption` 的密文（它的密钥派生和格式不同）。

### 密钥与轮换

有 `encrypts` 的模型会让应用需要 openssl，并且 `CYBERTRAIN_ENCRYPTION_KEY` 不是 64 个十六进制字符时启动失败（用 `cybertrain secret --hex` 生成；[环境变量](configuration.md#configuration-and-environment-variables)）。该密钥不由 `CYBERTRAIN_SECRET_KEY_BASE` 派生，所以轮换会话密钥后数据仍可读取；丢失加密密钥，数据也就丢失了。要轮换它，把新密钥放进 `CYBERTRAIN_ENCRYPTION_KEY`，旧密钥放进 `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS`（逗号分隔；只用于读取），然后重写每一条记录：

```ruby
Account.find_each { |account| account.update_columns(api_key: account.api_key) }
```

在没有 `encrypts` 的应用中自行调用 `Cybertrain::Crypto.encrypt(text)` / `Crypto.decrypt(payload)` 的代码，需要在 `bin/<app>.rb` 中加上 `require "cybertrain/encryptor"` 并设置密钥。

### 加密已有文本的列

在加上 `encrypts` 之前写入的行存的是明文，读取这样的行会抛出 `Cybertrain::Encryptor::Error`。通过应用命令（`./<app> encrypt_api_keys`）用 SQL 一次性加密它们：

```ruby
# bin/<app>.rb
Cybertrain::Main.command("encrypt_api_keys", "encrypt accounts.api_key written before encrypts") do |_argv|
  Cybertrain::DB.transaction do |c|
    c.execute("SELECT id, api_key FROM accounts WHERE api_key IS NOT NULL AND api_key NOT LIKE '1:%'").each do |row|
      payload = Cybertrain::Crypto.encrypt(Cybertrain::Cast.str(row["api_key"]))
      c.execute("UPDATE accounts SET api_key = ? WHERE id = ?", [payload, Cybertrain::Cast.int(row["id"])])
    end
  end
  0
end
```

`NOT LIKE '1:%'` 防止第二次运行再次加密密文；如果明文可能以 `1:` 开头，请去掉它。Rails 加密过的值，先在 Rails 应用中解密，再在这里用同样的方式加密。

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
min: 1, max: 100)` 对任意键进行同样有界的读取（可选的 `-` 加上最多 18 位数字，否则取默认值；限制在 `min..max` 范围内）。

`relation.page(n, per: 50)` 在 relation 上设置 `LIMIT per OFFSET (n - 1) * per`（会替换之前的 `limit`/`offset`，所以请最后调用它），以同样的方式限制 `n`，因此偏移量永远不会超过 `(max_page - 1) * per`，并返回一个 `Cybertrain::Page`：`number`、`per`、`row_offset`、`next?`（在窗口上用一条 `SELECT 1 ... LIMIT per + 1` 查询得出，不使用 `COUNT(*)`）、`prev?`、`next_number`、`prev_number`。行仍然留在 relation 上，所以 `@articles.each` 产出带类型的 `Article`；`per` 超出 1..1000 时会引发 `ArgumentError`。

`paginate @page, path` 渲染 `<nav class="pager">`，其中有 “Newer” 链接（`rel="prev"`）、“Page N” 和 “Older” 链接（`rel="next"`），没有对应页面时相应的链接会省略；这些链接保留当前的查询字符串，只替换 `page`（第 1 页时去掉它），并重新编码和转义，所以搜索或筛选条件在翻页后仍然保留；而带有自己查询字符串的路径（`"/search?q=x"`）则改用它自己的查询字符串。

仅支持偏移分页：适用于超大表的键集分页（`after: id`）尚未实现。脚手架生成的 index 视图会列出所有记录；加上上面三行即可对它分页。

## 事务

`Cybertrain::DB.transaction { |c| ... }`（或 `Article.transaction`，同一个东西换成 Rails 的名字）会取出一个连接，运行 `BEGIN`，把连接传给块，块返回时 `COMMIT`，块抛出异常时回滚并重新抛出。`immediate: true` 运行 `BEGIN IMMEDIATE`，它在开始时就获取 SQLite 的写锁：先读后写的事务应使用它，这样并发的写入者会让它在 `BEGIN` 处等待，而不是在第一次写入时以 “database is locked” 失败。块运行期间，该线程上所有经过连接池的操作（`save`、`update`、`destroy`、Relation 查询、`DB.with`）都使用事务的连接，因此都属于这个事务：

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

它与 Rails 的 `transaction` 的不同之处，以及应避免的做法：

- 它返回 nil，而不是块的值。
- 通过抛出异常退出，回滚之后异常会被重新抛出（Rails 用 `raise ActiveRecord::Rollback` 退出）。
- 嵌套在块中的 `DB.transaction` 会加入外层事务：只有最外层提交，任何地方抛出异常都会回滚全部内容，没有保存点（没有 `requires_new: true`）。
- 在 Spinel 下不能对传入的 `c` 调用 `c.transaction { }`：请嵌套 `DB.transaction`，或使用下面不带块的形式。
- 在 `DB.with` 块（它不是事务）中调用的 `DB.transaction` 会取出第二个连接：在只有一个连接的连接池上（包括 `:memory:`），它会因此永远等待下去。请先开启事务，再在其中完成工作。
- 不要在块中 rescue 数据库错误后继续执行。出现 “database or disk is full”、I/O 错误或锁等待超时后，SQLite 可能会自行回滚整个事务。此后块中的每条语句都会抛出 `Cybertrain::DB::Error`（“the enclosing transaction is no longer open”），而不是单独提交，块结束时事务也会抛出异常。请让错误离开块，需要时重试整个事务。用 `c.exec_script("BEGIN")` 开启的事务也同样处理，直到 `COMMIT`、`END` 或 `ROLLBACK` 结束它；此时的 `ROLLBACK` 什么也不做并直接成功，因为 SQLite 已经回滚了该事务。

必须把 `rescue` 写在普通方法中的代码可以使用不带块的形式：`c.begin!(immediate: true)` ... `c.commit!`，并在 rescue 中调用 `c.rollback!`。

## 列名

列名必须是 ASCII 标识符（`[A-Za-z_][A-Za-z0-9_]*`），而 Rails 接受任何列名。带有非 ASCII 列名（`名前`、`prénom`）的 schema 在 PR #10 之前可以在 CRuby 下生成，现在 `spin run gen` 会拒绝它，所以升级时请重命名该列（像 `first-name` 这样的名字从来都不是合法的方法名）。

如果列名与生成的类或框架在记录上调用的方法同名（`errors`、`save`、`attributes`、`hash`、`to_s`、`to_ary`、`raise` 等），或与 Ruby 关键字同名（`end`、`class`、`begin`），就会以 `<column>_column` 的名字生成（`hash_column`：读方法、写方法和实例变量），并在生成的文件中附上说明。它的两个名称这样使用：

- 它的 SQL 名称在 `read_attribute`、params 和 `attributes["hash"]` 中仍然有效。
- 模板可以用任一名称访问它（`post.hash`、`post.hash_column`），但 `errors` 和 `to_param` 除外，模板会把它们解析为模型方法，所以在模板中要用 `post.errors_column`。
- 查询 API（`where`、`order`、`find_by`）始终使用 SQL 列名（`Post.where(hash: 1)`）；Ruby 名称只用于读写方法和模板。

与 Object 的其他方法同名的列（`display`、`tap`、`methods`）以原名生成，并附上说明。`cybertrain generate scaffold` 会拒绝关键字和保留名称（否则它就得调用改过名的读方法），对会遮蔽方法的名称则接受并附上说明，与生成器一致。

如果某个关联的普通名称已被某列、另一个关联或 `Model` 的方法占用（Rails 允许关联遮蔽 `errors`），就会以后备名称生成，并在生成的文件中附上注释：`has_many` 用 `<table>_as_<column stem>`（`comments_as_article`），`belongs_to` 用 `<stem>_as_<column>`（`author_as_author_id`）。

## 二进制列

`t.binary` 创建一个 `BLOB` 列，用于存放不是文本的字节：缩略图、压缩的快照、密钥。属性是一个 String，原样保存所存储的字节，包括 NUL 字节和大于 127 的字节；`NULL` 时为 `nil`（除非声明 `null: false`，否则该列可为空，所以在添加该列之前保存的照片没有缩略图：调用 `bytesize` 之前请先检查 `nil`）：

```ruby
# db/migrate/20261105090000_add_thumbnail_to_photos.rb
class AddThumbnailToPhotos < Cybertrain::Migration::Base
  def change
    add_column "photos", "thumbnail", :binary
  end
end
```

```ruby
photo.thumbnail = File.binread("thumb.webp")
photo.save
Photo.find(photo.id).thumbnail.bytesize   # 读回的是同样的字节
```

- 生成的模型在保存时把二进制列作为 BLOB 绑定；其他 String 仍然作为 TEXT 绑定，而 TEXT 会在 NUL 字节处截断。在原始 SQL 中，把字节包进 `Cybertrain::DB::Blob.new(bytes)`，即可作为 BLOB 绑定（`c.execute("INSERT INTO photos (thumbnail) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`）。
- `Photo.where(thumbnail: bytes)` 同样把字节绑定为 BLOB（TEXT 绑定永远不等于已存储的 BLOB）。
- 用原始 SQL 读出的 BLOB 单元格是由其字节组成的 String；`Cybertrain::Cast.binary(value)` 用于收窄它（`NULL` 时为 `""`）。
- `db/schema.rb` 会把该列重新写成 `t.binary`，控制台把二进制值打印为 `<N bytes>`。
- 不要把大文件放进数据库：上传的文件（[添加文件上传](tutorial.md#attachments)）是 `storage/uploads/` 下的一个文件，而 BLOB 会连同所在的行一起被整个读入内存，并让每次备份和 WAL 都变大。

## 排序

Rails 的 `order` 接受任何 SQL（`order("lower(title)")`、`order("posts.title")`、`order(params[:sort])`），而这里的 `order` 只接受 `column [ASC|DESC]` 列表（每个列名都会加引号），遇到其他内容会抛出 `ArgumentError`：返回 500，因为这个字符串是开发者写的。

请求数据必须先经过允许列表，因为格式正确的项仍可能指向不存在的列（SQLite 返回 500），或客户端不应据以排序的列：

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

原始的 ORDER BY 文本要通过 `order_sql`（`Post.order_sql("lower(title)")`，relation 上也有），它绝不能接触请求数据。

## 接管 Rails 创建的数据库

Rails 8 应用创建的 SQLite 文件可以直接读取：

1. 把它复制到应用的数据库路径，默认为 `storage/development.sqlite3`（`storage/<env>.sqlite3`，或 `CYBERTRAIN_DATABASE` 指向的位置）。
2. 运行 `cybertrain db schema`（对构建好的二进制为 `./<app> db schema`）。它用 `db migrate` 所用的导出器根据数据库写出 `db/schema.rb`，打印 `wrote .../db/schema.rb from <path>`，此外什么都不做。之后 `cybertrain db migrate` 找不到需要应用的内容，并生成模型。
3. 不要复制 Rails 的 `db/migrate/*.rb`：新的迁移从这里开始。`schema_migrations`（两边是同一张表）中已有的 Rails 版本在这里没有文件，所以迁移器既不运行也不回滚它们，`db status` 把它们列为 `applied (no file)`。
4. 不需要转换的：日期时间（Rails 的格式就是存储格式）、布尔值（`1` / `0`，以及旧的 `t` / `f`）、decimal（Rails 写的是 REAL 值，读作 Float）、json（TEXT，读作 Hash），以及 Rails 写的类型名（`datetime(6)`、`decimal(18,8)`、`varchar`、`bigint`、`json`）。部分索引、表达式索引和 `ON DELETE` 动作也会导出。
5. 限制：主键不是 `id` 列的表（连接表）会导出为 `create_table "articles_tags", id: false`，没有模型（`spin run gen` 会打印 `skipped articles_tags: no id column`），通过 `DB.with` 访问；`ar_internal_metadata` 保持不动；`CREATE TABLE` 中含有 schema 无法表达内容的表，不能用重建类辅助方法修改（[修改表](#changing-a-table)）；Rails 加密过的列需要重新加密（[加密已有文本的列](#encrypting-a-column-that-already-holds-text)）。

然后按本页所示的形式，在 `app/models/*.rb` 中写出 Rails 模型原有的校验、关联和 scope。

## 从 0.4 升级

下面每一项都是为 CyberTrain 0.4 编写的应用一次就能改完的修改：

1. `has_many` 读取方法返回 relation，而不是 Array：在仅 Array 才有的方法（`map`、`select`、`[]`、`+`）前加 `.to_a`。模板不变。
2. 日期时间以 Rails 的格式存储：升级后运行一次 `db normalize`（[日期时间与 `db normalize`](#datetimes-and-db-normalize)）；在那之前，混有两种格式的列按格式排序。
3. `as_json` 和 `to_json` 把时间写成 `2026-10-05T09:00:00.000Z`（以前是 `2026-10-05T09:00:00Z`）：测试中的 JSON 快照会变化。
4. `t.date` 属性是 `Date`，不是 String：`strftime` 仍然可用，拼接需要 `to_s`。NOT NULL 的日期列现在会校验存在性。
5. 没有 `optional: true` 的已声明 `belongs_to` 会校验其外键；未声明的不变。
6. Integer 端点的 `where(x: a..b)` 是范围条件（以前是与 Range 文本的相等比较，永远不会匹配）；Time 和 Date 边界使用 `where_between`。
7. `Cybertrain::Cast.iso8601` 是显示格式：用它拼 SQL 文本的代码改用 `Cast.sql_datetime`，`Cast.binds` 以存储格式绑定 Time。
8. `validates` 行上的 `allow_blank: true` 也让该行的 `presence` 放过空白值，与 Rails 相同（以前只作用于 `length`）。
9. 与每个模型现在都有的方法同名的列（`update_columns`、`destroy_dependents`、`run_custom_validations` 等）会生成为 `<column>_column`（[列名](#column-names)）。
10. `belongs_to` 读取方法会记住读到的父记录，直到外键改变（以前每次调用都会重新读取）：要看到其他进程所做的修改，请调用 `reload`。
