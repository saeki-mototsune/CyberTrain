---
source_sha256: d62a91b26f80349bd7e891915008018ac461080efd3d2b307d2642cc718b3687
---
# Модели и база данных

## Миграции

Миграция в `db/migrate/<version>_<name>.rb` — это подкласс
`Cybertrain::Migration::Base`. Его `change` записывает операции над схемой
(`create_table`, `add_column`, `add_index`, `rename_column`, `add_reference`,
`remove_column`, `remove_index`, `drop_table`); `cybertrain db migrate`
применяет каждую ожидающую версию в собственной транзакции и перезаписывает
`db/schema.rb` по базе данных, а `cybertrain db rollback [N]` выполняет
обратное к `change`. Когда в `change` есть операция без автоматической обратной,
напишите `down` (и `up`).

Изменение схемы, которому для безопасности нужен шаг с данными, использует
`execute(sql, binds = [])`. Он выполняется на своём месте в миграции, на
собственном соединении мигратора и в той же транзакции, что и операции над
схемой этой версии, поэтому добавленный перед ним столбец к моменту его
выполнения уже существует, а сбой отменяет всю версию:

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # существующие строки сохраняют «навсегда»
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

Без параметров привязки SQL может состоять из нескольких выражений,
разделённых `;`; с параметрами — это одно выражение с заполнителями `?`. У
`execute` нет обратной операции: откат `change`, который выполняет SQL и не
имеет собственного `down`, останавливается с
`version N is irreversible: it executes SQL in change; write down`, прежде чем
что-либо будет отменено. Выражение с данными никогда не появляется в
`db/schema.rb`, который выгружается из базы данных. Запись миграции ничего не
выполняет, поэтому выражение выполняется ровно один раз на каждый `migrate`
своей версии.

## Запросы помимо `where`

Сгенерированные relation охватывают `where` / `where_sql` / `order` / `limit` /
`offset` / `count` / `exists?` / `delete_all`. Для счётчиков, статистики и полей
поиска, которые тоже нужны большинству приложений, есть типизированные
дополнения (issue #74, `docs/design.md` D22), а не построитель запросов; каждое
принимает имена столбцов SQL, проверенные и взятые в кавычки (всё остальное —
`ArgumentError`), и привязывает каждое значение:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; возвращает число записанных строк
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   (также pluck_str, pluck_float)
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # группы по часам
Stat.where(project_id: 1).sum_int(:calls)                 # также sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- Значения `update` у `upsert` и выражение `count_by_sql` — это текст SQL, как
  и у `order_sql`: никогда не стройте их из данных запроса. Пустой `update` —
  это `DO NOTHING`. `upsert` и `increment` не загружают модель, не выполняют
  валидаций и колбэков и не заполняют временные метки.
- Ключи `count_by` — строки (через `Cast.str`), по возрастанию; NULL и `""`
  делят ключ `""`. С `limit` / `offset` методы `count_by`, `sum_*` и
  `increment` работают в этом окне, как и `count` и `delete_all`.
- `where_like` — поиск подстроки (без учёта регистра для ASCII, как LIKE в
  SQLite). Поиск по префиксу пишет собственный шаблон:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- Для SQL, написанного вручную, `Cybertrain::Cast.binds(a, b, c)` строит массив
  параметров привязки, который принимает `execute` (Time — как текст UTC ISO 8601,
  булевы значения — как 1/0):
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` сужают разобранное значение JSON
  до Hash / Array или до нового пустого, если оно им не является (Time
  проверяется первым, spikes/NOTES.md, правило 8). Они возвращают
  типизированную поверхностную копию, а не сам `v`; `Cast.empty_hash` /
  `Cast.empty_array` — это пустые контейнеры с заранее заданным типом.

## Постраничный вывод

Страница списка читает номер страницы из `?page=N`, ограничивает relation окном
и выводит ссылки:

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

`params.page_number` — параметр `page`, считающийся от 1; он равен 1, когда
отсутствует или не является числом, и ограничен диапазоном `1..max_page`
(`config.max_page`, по умолчанию 10000, `CYBERTRAIN_MAX_PAGE`); он никогда не
передаёт неограниченный текст в `String#to_i`, который под Spinel возбуждает
`RangeError` за пределами 2**63-1. `params.int(:per, default: 20,
min: 1, max: 100)` — такое же ограниченное чтение для любого ключа
(необязательный `-` и не более 18 цифр, иначе значение по умолчанию; ограничено
диапазоном `min..max`). `relation.page(n, per: 50)` задаёт relation
`LIMIT per OFFSET (n - 1) * per` (заменяя прежние `limit`/`offset`, поэтому
вызывайте его последним), ограничивает `n` так же, поэтому смещение никогда не
превышает `(max_page - 1) * per`, и возвращает `Cybertrain::Page`: `number`,
`per`, `row_offset`, `next?` (определяется одним
`SELECT 1 ... LIMIT per + 1` по окну, без `COUNT(*)`), `prev?`,
`next_number`, `prev_number`. Строки остаются в relation, поэтому
`@articles.each` выдаёт типизированные `Article`; `per` вне 1..1000 — это
`ArgumentError`. `paginate @page, path` выводит `<nav class="pager">` со ссылкой
«Newer» (`rel="prev"`), «Page N» и ссылкой «Older» (`rel="next"`); каждая
опускается, если такой страницы нет; ссылки сохраняют текущую строку запроса с
заменённым `page` (для страницы 1 он убирается), заново закодированную и
экранированную, поэтому поиск или фильтр сохраняются при листании, а путь с
собственной строкой запроса (`"/search?q=x"`) использует вместо этого её.
Только постраничный вывод по смещению: постраничный вывод по ключу (`after: id`)
для очень больших таблиц пока не реализован. Представление index из скаффолда
выводит все записи; чтобы разбить его на страницы, добавьте три строки выше.
