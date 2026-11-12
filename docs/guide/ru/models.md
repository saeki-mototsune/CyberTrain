---
source_sha256: 9162d493e7eb52e7625532b986b86fdb3271d8d3052a33e516ddadcb0a9690ba
---
# Модели и база данных

Что модель делает помимо скаффолда: миграции, типы столбцов, запросы,
ассоциации, валидации, зашифрованные столбцы, постраничный вывод, транзакции,
правила, которым под Spinel подчиняются имена столбцов и конструкции `order`,
и перенос базы данных, созданной Rails.

## Миграции

Миграция в `db/migrate/<version>_<name>.rb` — это подкласс
`Cybertrain::Migration::Base`. Его `change` записывает операции над схемой
(`create_table`, `add_column`, `add_index`, `rename_column`, `add_reference`,
`remove_column`, `remove_index`, `drop_table` и операции из раздела
[Изменение таблицы](#changing-a-table)); `cybertrain db migrate`
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

### Индексы и внешние ключи

`add_index` принимает `where:` для частичного индекса; `t.references`
принимает `on_delete:` и `index: false`, а `add_reference` принимает
`on_delete:` и всегда добавляет индекс:

```ruby
create_table "comments" do |t|
  t.references :article, on_delete: :cascade   # ON DELETE CASCADE
  t.references :author, null: true, on_delete: :nullify, index: false
  t.text "body"
  t.timestamps
end
add_index "comments", ["body"], where: "body IS NOT NULL"
```

`on_delete:` — это `:cascade`, `:nullify` (столбец должен допускать NULL) или
`:restrict`; по умолчанию предложение `ON DELETE` не пишется (`NO ACTION` в
SQLite). Что выбрать, сказано в разделе [`dependent:` или
`on_delete:`](#dependent-or-on_delete). У индекса по выражению
(`LOWER(email)`) нет помощника миграций: создайте его через
`execute "CREATE UNIQUE INDEX index_users_on_lower_email ON users (LOWER(email))"`.
`db/schema.rb` выгружает его обратно как `s.add_index "users", "LOWER(email)", unique:
true, name: "index_users_on_lower_email"`, а дамп сохраняет и `where:`
частичного индекса.

### Изменение таблицы

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

- `rename_table` — это `ALTER TABLE ... RENAME TO`, и внешние ключи, которые
  указывают на таблицу, следуют за ней. Её индексы сохраняют имена (Rails
  переименовывает их под новую таблицу).
- Остальные пять перестраивают таблицу, потому что в SQLite нет
  `ALTER COLUMN`: по изменённому определению создаётся новая таблица, строки
  копируются, старая таблица удаляется, новая переименовывается, а её индексы,
  триггеры и верхняя отметка `AUTOINCREMENT` восстанавливаются. Представления
  и триггеры других таблиц, которые её упоминают, продолжают работать.
- `change_column` объявляет столбец заново: опции, которые ему не переданы
  (значение по умолчанию, `null: false`), пропадают, как в Rails.
- `change_column_default` требует `to:` (литеральный текст SQL, `nil` убирает
  значение по умолчанию); `from:` называет прежнее значение и делает операцию
  обратимой.
- Четвёртый аргумент `change_column_null` — значение, которое записывается в
  ячейки NULL перед добавлением `NOT NULL`; значением по умолчанию столбца оно
  не становится.
- `remove_foreign_key :articles, :authors` удаляет ключ, а столбец и его
  индекс оставляет (`column:` называет другой столбец, чем `author_id`).

`rename_table` и `change_column_default` с `from:` обращаются сами внутри
`change`; `change_column_null` тоже, только для отката `null: true` нужен
четвёртый аргумент для ячеек, ставших NULL с тех пор. `change_column`,
`remove_reference` и `remove_foreign_key` в `change` необратимы: напишите
`up` и `down`.

<details><summary>Что перестройка отвергает и внешние ключи во время неё — CHECK, COLLATE, генерируемые столбцы и прочее</summary>

Перестройка объявляет таблицу по тому, что умеет выразить `db/schema.rb`.
Прежде чем трогать таблицу, она читает её текст `CREATE TABLE` и отвергает
таблицу со всем, чего схема не моделирует (`rebuilding posts would drop a
CHECK constraint: rewrite the migration with execute`), и версия
откатывается. Сюда входят ограничение `CHECK` или встроенное `UNIQUE`
(уникальный индекс годится), `COLLATE`, генерируемый столбец, `ON UPDATE`,
`ON DELETE SET DEFAULT`, `DEFERRABLE`, внешний ключ на столбец, отличный от
`id`, столбец без типа, первичный ключ, отличный от `id`, и таблицы
`WITHOUT ROWID` или `STRICT`. Проверка ищет эти слова в тексте SQL и не
является парсером, поэтому прочитайте выгруженную схему написанной вручную
таблицы, прежде чем её перестраивать. Простой `id INTEGER PRIMARY KEY`
возвращается как `AUTOINCREMENT`, что сохраняет каждую строку и каждый id.
Точные написания типов нормализуются (`datetime(6)` становится `DATETIME`).

Версия с перестройкой выполняется с выключенным `PRAGMA foreign_keys` (внутри
транзакции его не выключить, поэтому мигратор делает это вокруг версии) и
перед фиксацией запускает `PRAGMA foreign_key_check`: нарушение откатывает
версию и называет строки. Проверка охватывает всю базу, так что нарушение,
уже имеющееся в другой таблице, тоже останавливает версию, как в Rails.

</details>

### Шаги с данными в обе стороны: `reversible`

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

Операторы `dir.up` выполняются при миграции, а `dir.down` — при откате,
каждый в записанном порядке. Внутри блоков допустим только `execute`.
Недоступно: `create_join_table`, `change_table`, `rename_index`,
`add_timestamps`.

`cybertrain db status` перечисляет все версии; версия из
`schema_migrations` без файла в `db/migrate` (база, которую мигрировал другой
инструмент) показывается как `applied (no file)`, и мигратор её не выполняет
и не откатывает. `cybertrain db schema` пишет `db/schema.rb` по базе без
миграции ([Перенос базы данных, созданной
Rails](#taking-over-a-database-rails-created)).

## Типы столбцов

| DSL схемы | SQL | Атрибут Ruby |
| --- | --- | --- |
| `t.string`, `t.text` | `VARCHAR(n)` / `VARCHAR`, `TEXT` | String |
| `t.integer`, `t.bigint`, `t.references` | `INTEGER`, `BIGINT` | Integer |
| `t.float` | `FLOAT` | Float |
| `t.decimal :price, precision: 18, scale: 8` | `DECIMAL(18,8)` | Float, округлённый до scale при записи |
| `t.boolean` | `BOOLEAN` | true / false |
| `t.datetime` | `DATETIME` | Time (UTC, микросекунды) |
| `t.date` | `DATE` | Date |
| `t.json :meta, default: "{}"` | `JSON` | Hash со строковыми ключами |
| `t.binary` | `BLOB` | String из байтов ([Двоичные столбцы](#binary-columns)) |

Атрибут столбца, допускающего NULL, может быть и nil. `new`, `update` и
`write_attribute` приводят то, что им передано (`"42"` в целочисленный
столбец даёт `42`, `"2026-10-05"` в столбец даты — Date); простой writer
`post.price = ...` не приводит. INTEGER в SQLite 64-битный, так что
`t.bigint` — целочисленный столбец под другим именем.
`t.datetime :x, precision: 6` принимается; любой datetime хранит
микросекунды.

### Десятичные числа — это Float

Rails читает столбец `decimal` как BigDecimal; здесь это Float, и
сгенерированная модель округляет его до `scale:` столбца всякий раз, когда
он записывается (`save`, `update_columns`, `update_all`, массовые записи),
так что хранится то, что Rails сохранил бы после присваивания. BigDecimal
Spinel пока нельзя построить из Float или String и нельзя округлить; это
условие для пересмотра решения (`docs/design.md` D42). Двоичная плавающая
точка накапливает ошибку в длинных суммах: округляйте на краю
(`total.round(2)`) или храните деньги в минимальных единицах в
целочисленном столбце (`price_cents`).

### Столбцы JSON

Столбец `json` хранит объект, читается как `Hash` (`{}` для столбца NOT NULL,
текст которого не является объектом JSON, nil для допускающего NULL) и
пишется через `JSON.generate`. Его значения упакованы, как любое разобранное
значение JSON под Spinel, поэтому читайте их через `Cybertrain::Cast`:

```ruby
event.meta = { "attempts" => 2, "tags" => ["a", "b"] }
event.save
Cybertrain::Cast.int(event.meta["attempts"])   # => 2
Cybertrain::Cast.array(event.meta["tags"])     # => ["a", "b"]
```

Присвоенный текст, который не является корректным JSON, становится `{}`.
Array в корне не поддерживается: храните его в столбце `text` и читайте
через `Cast.array`. `where` по столбцу json выбрасывает `ArgumentError`, а
`pluck` отвечает сохранённым текстом.

### Дата-время и `db normalize`

Значение datetime хранится так, как его хранит Rails в SQLite,
`2026-10-05 09:00:00.000000` (UTC, пробел, шесть цифр дробной части), и
читается с `T` или пробелом, с любой дробной частью и с `Z` или смещением.
JSON (`as_json`, `to_json`) пишет форму отображения Rails,
`2026-10-05T09:00:00.000Z`. В написанном вручную SQL
`Cybertrain::Cast.sql_datetime(time)` даёт хранимый текст, а
`Cast.iso8601(time)` — текст для отображения.

CyberTrain 0.4 хранил `2026-10-05T09:00:00Z`, что сортируется после любого
значения в формате Rails независимо от даты. Один раз после обновления
перепишите старые ячейки:

```console
$ cybertrain db normalize
normalized articles.created_at: 12 rows (0 unreadable left alone)
normalized articles.updated_at: 12 rows (0 unreadable left alone)
done
```

Команда переписывает каждую ячейку каждого столбца `DATETIME`
(включая `datetime(6)`), которая ещё не в хранимом формате, строку за строкой
в одной транзакции, и её безопасно запускать дважды. Ячейка, которую нельзя
прочитать как время (с лишним текстом вроде ` UTC`), остаётся как есть и
учитывается. Таблица `WITHOUT ROWID` или таблица со столбцом `_rowid_`
пропускается; если в ней ещё есть старые ячейки, команда печатает
`skipped t.c: without rowid (N rows still need normalization)` (или
`declares _rowid_`) и завершается с кодом 1: обновите эти строки вручную и
запустите её снова. Нужен SQLite 3.37.0 или новее: CyberTrain связывается с
системной libsqlite3 (её показывает `sqlite3 --version`), а с более старой
команда останавливается на `db normalize failed: ...`, ничего не прочитав. В
продакшене запускайте `./<app> db normalize` между `migrate` и
запуском новых бинарников ([развёртывание
обновления](../deploy.en.md#upgrading-the-framework)).

### Даты

Столбец `date` — это `Date` (`Date.new(2026, 10, 5)`), хранимая как
`2026-10-05`; `where(day: date)` привязывает её этим текстом. Присваиваемый
текст должен быть `YYYY-MM-DD`: всё прочее (или пустое) читается обратно как
nil. Столбец даты NOT NULL получает сгенерированную проверку присутствия, так
что `save` возвращает false с «can't be blank», а не база отвергает строку;
столбец со значением по умолчанию начинает с него.
`Cybertrain::Cast.date_or_nil(params[:from])` так же читает параметр даты.

### Разбор времени

`Time.iso8601(text)`, `Time.rfc2822(text)` и `Time.strptime(text, format)`
доступны под своими именами из Ruby, и каждый выбрасывает `ArgumentError` на
тексте, который не может прочитать. `strptime` принимает `%Y %m %d %H %M %S
%L %z %Z %b %B %a %A %j %s %%` (`%Z` — только `UTC`, `GMT` или `Z`).
`Time.at(ms / 1000.0)` превращает эпоху в миллисекундах в Time.

## Условия и поиск

Методы запроса сгенерированного relation есть и как методы класса (все,
кроме `or`, `not`, `page` и `to_sql`, и похожих на Array `to_a`, `each`,
`size`, `empty?`), так что запись из Rails работает как есть:
`Article.where.not(body: nil)`, `Article.find_each { }`,
`Article.pluck(:id, :title)`, `Article.pluck_int(:id)`.

| Rails | CyberTrain |
| --- | --- |
| `where(views: 1..10)`, `where(views: 10..)` | То же, только с концами Integer |
| `where(created_at: from..to)` | `where_between(:created_at, from, to)` (`exclude_end: true` для `...`; nil для открытого конца) |
| `where("views > ?", 10)` | То же |
| `where.not(state: "draft")`, `a.or(b)` | То же |
| `order(created_at: :desc)` | То же |
| `distinct`, `none`, `ids` | То же |
| `find_by!`, `find_or_create_by`, `find_or_initialize_by` | То же |
| `update_all`, `destroy_all`, `find_each(batch_size: 500)` | `update_all`, `destroy_all`, `find_each(batch: 500)` |
| `create!`, `record.update_columns(views: 0)` | То же |

- Range в Hash для `where` принимает концы Integer: под Spinel нельзя
  построить Range из Time или Date, а Range из Float или String не
  распознаётся как Range, поэтому такие границы идут через `where_between`,
  чьи границы Time и Date сравниваются как хранимый текст (который
  упорядочен так же, как моменты времени).
- Строковое условие заключается в скобки, так что `OR` в нём остаётся
  внутри. Его binds — скаляры: `where("id IN (?)", ids)` выбрасывает
  исключение; пишите `where(id: ids)`.
- `a.or(b)` — это `((a) OR (b))`; у обоих должны совпадать порядок, limit,
  offset и `distinct`.
- `where` по столбцу json или зашифрованному столбцу выбрасывает
  `ArgumentError`.
- `distinct` заставляет методы чтения столбцов возвращать каждое значение
  один раз, а агрегаты — читать различающиеся значения (`SUM(DISTINCT x)`);
  `count` и `to_a` не меняются, ведь у каждой строки свой id.
- `update_all(hash)` приводит и округляет так, как сохраняет `save`, кроме
  того, что `""` в числовом, логическом столбце, столбце даты или json
  привязывается как NULL (`save` сохранил бы 0 / false / `{}`), не
  трогает `updated_at` и не запускает колбэки; `destroy_all` уничтожает
  каждую запись вместе с колбэками и `dependent:`.
- `update_all_sql(sql, binds = [])` задаёт столбцы SQL-списком `SET` — для
  значения, вычисляемого из строки (`User.where(id: id).update_all_sql("failed_attempts = failed_attempts + ?", [1])`);
  каждое выражение читает строку такой, какой она была, `?` берёт привязки
  по порядку, и, как `update_all`, он не загружает модель и не вызывает
  колбэков.
- `find_each` обходит записи по id пачками и, как Rails, игнорирует порядок,
  limit и offset relation.
- `find_or_create_by` на суженном relation создаёт запись только из
  переданного ему Hash; Rails берёт ещё и условия равенства relation.
  Передавайте все атрибуты, которые нужны новой записи.
- `update_columns` присваивает значения, затем выполняет один UPDATE этих
  столбцов: без валидаций, без колбэков, `updated_at` не меняется.

## Скоупы

```ruby
# app/models/article.rb
class Article
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where("created_at > ?", time) }
end

Article.recent.since(Time.now - 86_400).limit(5).to_a
```

Генератор читает каждую строку `scope` как текст и копирует параметры и тело
лямбды в метод relation модели (`def since(time) = (where("created_at > ?",
time))`) и в метод класса, который ему делегирует, так что скоупы
выстраиваются в цепочку, как любой запрос. При генерации ничего не
вычисляется: тело, которое называет то, чего нет у relation, падает, когда
Spinel компилирует `gen/models`, на сгенерированной строке.

Скоуп — одна строка на уровне класса: лямбда `->` с простыми или имеющими
значение по умолчанию позиционными параметрами, ничего после закрывающей `}`
(даже комментария) и без скобок или запятых в значении по умолчанию. Скоуп,
названный как столбец, другой скоуп, метод запроса (`where`, `count`,
`first`) или метод `Object` (`hash`, `then`, `raise`), останавливает
генератор с указанием файла, строки и причины.

## Запросы помимо `where`

Помимо условий выше, счётчики, статистика и поля поиска, которые нужны
большинству приложений, есть в виде типизированных методов (`docs/design.md`
D22, D44, D45), а не построителя запросов; каждый принимает имена столбцов
SQL, проверенные и взятые в кавычки (всё прочее — `ArgumentError`), и
привязывает каждое значение:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; возвращает число записанных строк
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1 (by: n for another step)
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   (также pluck_str, pluck_float)
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # группы по часам
Stat.where(project_id: 1).sum_int(:calls)                 # также sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- Каждый из них типизирован, потому что у метода Spinel один тип возвращаемого
  значения: `pluck_str` / `pluck_int` / `pluck_float` читают только один
  столбец, `sum_int` / `sum_float` суммируют один, а `count_by` возвращает
  `Hash{String => Integer}`.
- Значения `update` у `upsert` и выражение `count_by_sql` — это текст SQL, как
  и у `order_sql`: никогда не стройте их из данных запроса. Пустой `update` —
  это `DO NOTHING`. `upsert` и `increment` не загружают модель, не выполняют
  валидаций и колбэков и не заполняют временные метки; `upsert` приводит
  каждое значение так же, как его сохраняет `save`.
- Ключи `count_by` — строки (через `Cast.str`), по возрастанию; NULL и `""`
  делят ключ `""`. С `limit` / `offset` методы `count_by`, `sum_*` и
  `increment` работают в этом окне, как и `count` и `delete_all` (через
  подзапрос).
- `where_like` экранирует `\`, `%` и `_` в тексте за вас и ищет подстроку (без
  учёта регистра для ASCII, как LIKE в SQLite). Поиск по префиксу пишет
  собственный шаблон:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- Для написанного вручную SQL `Cybertrain::Cast.binds(a, b, c)` собирает
  Array привязок, который принимает `execute` (Time — в хранимом формате
  datetime, Date — как `YYYY-MM-DD`, логические значения — как 1/0):
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` сужают разобранное значение JSON
  до Hash / Array или до нового пустого, если оно им не является (Time
  проверяется первым, spikes/NOTES.md, правило 8). Они возвращают
  типизированную поверхностную копию, а не сам `v`; `Cast.empty_hash` /
  `Cast.empty_array` — это пустые контейнеры с заранее заданным типом.

### Несколько столбцов: `pluck` и `pick`

```ruby
Reading.order(:id).pluck(:observed_at, :value)   # => [[2026-10-01 09:00:00 UTC, 1.0], ...]
Reading.order(:id).pick(:id, :value)             # => [1, 1.0], or nil
```

`pluck` принимает два столбца или больше и отвечает одним Array на строку,
каждая ячейка приведена по типу своего столбца: Integer, Float (float и
decimal), `true` / `false`, Time в UTC, Date, String (столбцы string, text,
json и binary отвечают хранимым текстом или байтами, зашифрованный столбец —
шифротекстом) или nil. Один столбец выбрасывает `ArgumentError` с отсылкой к
`pluck_str` / `pluck_int` / `pluck_float` / `ids`: Rails отвечает плоским
Array для одного столбца и вложенными для нескольких, а один метод не может
возвращать и то и другое. `pick` — первая строка (`LIMIT 1`) или nil.
Принимаются только имена столбцов; выражение идёт через `DB.with`.

### Агрегаты

| Rails | CyberTrain |
| --- | --- |
| `minimum(:views)`, `maximum(:views)` | `minimum_int`, `maximum_int` (`Integer` или nil) |
| `maximum(:price)` по float или decimal | `minimum_float`, `maximum_float` |
| `maximum(:created_at)` | `minimum_time`, `maximum_time` (Time в UTC или nil) |
| `average(:value)` | `average(:value)` (Float или nil) |
| `group(:kind).sum(:value)` | `sum_float_by(:kind, :value)` (также `sum_int_by`) |
| `group(:kind).maximum(:created_at)` | `maximum_time_by(:kind, :created_at)` и `_by` для каждого метода выше |
| `sum("price * quantity")` | `sum_float_sql("price * quantity")`, также `minimum_float_sql`, `maximum_float_sql`, `average_sql` |
| `group(:kind).having("SUM(value) > ?", 2)` | `having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value)` |

- Имена несут тип по той же причине, что и `pluck_int`: `maximum` в Rails
  отвечает Integer для одного столбца и Time для другого.
- Методы `_by` отвечают `Hash{String => T}` с ключом — значением столбца
  группы в виде текста, по возрастанию, как `count_by`; NULL и `""` делят
  ключ `""`.
- `having_sql` относится к группирующим методам; любой другой метод чтения
  relation с ним выбрасывает исключение, как и группирующий метод с limit
  или offset.
- Выражения `_sql` и `having_sql` — доверенный SQL, как `order_sql`.
- Под `distinct` агрегаты читают различающиеся значения
  (`AVG(DISTINCT x)`); если есть ещё и limit, окно — это первые n
  различающихся значений.
- Агрегат по выражению *и* группе или по двум таблицам пишется через
  `DB.with`.

## Массовые записи

```ruby
Article.insert_all([{ title: "One", body: "..." }, { title: "Two", body: "..." }]).size  # => 2
Article.insert_all!(rows)                                 # a duplicate raises
Article.upsert_all([{ id: 1, title: "Renamed" }])         # body keeps its value
Article.upsert_all(rows, unique_by: [:slug], update_only: [:title], returning: [:id, :title])
```

`insert_all` пишет много строк многострочными операторами `INSERT` с
`ON CONFLICT DO NOTHING`, пропуская строку, которая конфликтует с
существующей; `insert_all!` вместо этого выбрасывает исключение;
`upsert_all` обновляет конфликтующую строку через
`ON CONFLICT (unique_by) DO UPDATE`. Результат — строки `RETURNING` (по
умолчанию `[{"id" => 3}, ...]`), приведённые по типу, так что `.size` — число
записанных строк.

- У каждой строки одни и те же ключи, иначе `ArgumentError` до какой-либо
  записи; неизвестный столбец или строки без ключей (`[{}]`) выбрасывают
  исключение так же. Столбцы, которые
  не называет ни одна строка, получают DEFAULT таблицы.
- Значения приводятся так же, как при `save` (Time в хранимом формате, Hash
  в JSON, decimal с округлением до его scale, Date в виде текста).
- `upsert_all` обновляет столбцы, которые дают строки, кроме `id`, столбцов
  `unique_by` и `created_at`; `update_only:` сужает этот список, а имя в нём,
  которого строки не дают, пропускается.
- `returning:`, `unique_by:` и `update_only:` принимают Array или одно имя
  (`returning: :id`); `false` — ни одного; любое другое значение
  выбрасывает `ArgumentError`.
- `created_at` / `updated_at` получают один `now` на весь вызов, когда они
  есть в таблице и их нет в строках, если только не `record_timestamps: false`.
- Операторы режутся по пределу привязок SQLite и выполняются в одной
  транзакции (присоединяясь к уже открытой), так что сбой не оставляет ничего
  от вызова; внутри транзакции, которую открыли вы, решает ваш откат.
- Не выполняются ни валидации, ни колбэки, ни шифрование: зашифрованный
  столбец в строке выбрасывает `ArgumentError`. Как в Rails, пропущенный
  дубликат всё равно расходует id.
- `RETURNING` требует SQLite 3.35.0 или новее (системной библиотеки, с
  которой связывается CyberTrain); более старая отвергает оператор своей
  синтаксической ошибкой (`Cybertrain::DB::Error`).

## Ассоциации

Внешний ключ даёт ассоциацию обеим сторонам без единой строки кода
(`t.references :article` даёт `Comment#article` и `Article#comments`). Файл
модели может и объявить их, чтобы переименовать или добавить опции:

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

- `has_many` возвращает relation детей, поэтому цепочки работают:
  `@article.comments.where(approved: true).count`,
  `@article.comments.find(params[:id])`. Добавьте `.to_a`, чтобы получить
  Array; шаблоны перебирают его как Array.
- `has_one` читает одного ребёнка (первого по id, если их несколько), nil,
  если его нет; он заменяет `has_many`, который дал бы внешний ключ.
- `belongs_to` читает родителя и хранит его, пока не изменится внешний ключ
  или не будет `reload`.
- Объявленный `belongs_to` без `optional: true` делает запись невалидной,
  пока её ключ nil, пуст или 0 («can't be blank» на `article_id`,
  сгенерированный `validates_foreign_key :article_id`), так что `save`
  возвращает false раньше, чем база отвергнет строку. Ассоциации только из
  внешнего ключа валидаций не добавляют.
- Опции — литералы: `class_name:` (String или Symbol), `foreign_key:`,
  `dependent:` (`has_many` и `has_one`), `optional:` и `counter_cache:`
  (`belongs_to`). Каждый макрос стоит один на своей строке, на уровне класса,
  без комментария в конце; несуществующая модель, столбец или опция
  останавливает генератор с указанием файла и строки.
- Недоступно: `has_many :through`, полиморфные ассоциации, лямбда-скоуп у
  `has_many` (продолжайте цепочку на возвращённом relation), `inverse_of`,
  `dependent: :restrict_with_error`.

### `dependent:` или `on_delete:`

`dependent:` выполняется внутри `destroy`, до DELETE родителя и в той же
транзакции: `:destroy` загружает каждого ребёнка и уничтожает его (его
колбэки и его собственный `dependent:` выполняются), `:delete_all` выполняет
один DELETE, `:nullify` — один UPDATE, ставящий ключ в NULL. `on_delete:` у
внешнего ключа ([Индексы и внешние ключи](#indexes-and-foreign-keys))
поручает это SQLite, кто бы ни удалял строку. Используйте
`dependent: :destroy`, когда у детей есть колбэки, счётчики или свои дети;
используйте `on_delete: :cascade` ради скорости и когда в базу пишут другие
программы. Без того и другого внешний ключ не даёт удалить родителя, у
которого ещё есть дети.

### Кэши счётчиков

`belongs_to :post, counter_cache: true` поддерживает `posts.comments_count`
(или `<имя has_many>_count`): +1 после создания ребёнка, -1 после его
уничтожения и обе стороны, когда ребёнок переходит к другому родителю, каждое
изменение — в собственной транзакции ребёнка. Столбец должен существовать
(целое число с `default: "0"`). Собственный `save` родителя оставляет его вне
своего UPDATE, поскольку его копия может устареть. Родитель, уничтожаемый с
`dependent: :destroy`, перед исчезновением уменьшает себя по разу на каждого
ребёнка, что безвредно.

### Предзагрузка через `includes`

```ruby
@articles = Article.recent.includes(:comments).to_a   # two queries
```

```erb
<% @articles.each do |article| %>
  <%= article.title %> (<%= article.comments.size %>)
<% end %>
```

`includes(*names)` (и `preload`, то же самое) выполняет ещё один запрос на
ассоциацию при загрузке записей (`Comment.where(article_id: ids)` для
`has_many` или `has_one`, родителей по id для `belongs_to`), так что цикл по
`article.comments` или `comment.article` своих запросов не выполняет. Запись
без детей получает пустой список, а отсутствующий родитель — nil, без
дальнейших запросов. У предзагруженного `has_many` `to_a`, `each`, `first`,
`last`, `size` и `empty?` отвечают из памяти (дети в порядке id); `count` и
`exists?` по-прежнему обращаются к базе, а метод цепочки (`where`, `order`,
...) отбрасывает предзагрузку и выполняет запрос как обычно. Только один
уровень (`includes(comments: :author)` нет), и у предзагруженного ребёнка не
выставлен родитель (`comment.article` читает его). `eager_load` и `joins`
недоступны.

## Валидации

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

Сообщения — умолчания Rails из встроенного словаря в локали запроса:
по-английски «can't be blank», «is too short (minimum is 3 characters)»,
«is the wrong length (should be 5 characters)», «is not included in the
list», «is reserved», «is invalid», «is not a number», «must be an
integer», «must be greater than or equal to 0», «has already been taken»,
по-японски «を入力してください» и т. д. Предел 1 даёт «1 character».
`message:` заменяет сообщение, на строке или внутри Hash правила;
`config/locales/` может заменить их для всех моделей или для одной
([Модели и сообщения валидации](i18n.md#models-and-validation-messages)).
`errors.full_messages` называет каждый атрибут через
`Post.human_attribute_name(:title)` («Title»; `author_id` — «Author»), а
сообщение на `:base` пишет отдельно.

- `length` принимает `minimum`, `maximum`, `is` и `in` (Range из Integer).
- `inclusion` и `exclusion` принимают Array или Range из Integer (других
  Range Spinel не строит); `1...5` пропускает 4.5 в столбце float, как в
  Rails.
- `numericality` сначала разбирает String (`"12"` проходит); Float не
  проходит `only_integer`, как в Rails.
- `uniqueness` спрашивает базу о другой строке с этим значением
  (`LOWER(col) = LOWER(?)` при `case_sensitive: false`, `IS NULL` для nil) в
  пределах `scope:`. На зашифрованном столбце её использовать нельзя.
- `allow_nil:` и `allow_blank:` пропускают nil или пустое значение для
  каждого правила своей строки, включая `presence`; `on: :create` или
  `on: :update` (один Symbol) выполняет строку только для новой или только
  для сохранённой записи.
- Неизвестная опция или значение не того вида выбрасывает `ArgumentError`
  при загрузке модели.

### Собственные валидации и условия

```ruby
class Booking
  validate :ends_after_start, on: :update, unless: :imported?

  def ends_after_start
    errors.add(:ends_on, "must be after the start") if ends_on < starts_on
  end

  def imported? = source == "import"
end
```

Строки `validate :method` выполняются после правил `validates`, по порядку.
`if:` и `unless:` (у обеих) принимают Symbol с именем метода модели,
столбца или ассоциации; генератор пишет таблицу, которая его вызывает,
потому что в Spinel нет `send`. Лямбда, `:if => :x` и `"if": :x`
останавливают генератор с сообщением, что нужно назвать метод, как и имя в
`validate`, которое файл модели не определяет. `validates_with`,
`validates_each`, `confirmation`, `acceptance` и `valid?(context)`
недоступны.

## Зашифрованные столбцы

```ruby
# app/models/account.rb
class Account
  encrypts :api_key
end
```

`encrypts` называет столбцы string или text (text лучше: хранимый
шифротекст длиннее текста). Сгенерированная модель шифрует значение, когда
пишет строку, и расшифровывает, когда читает, так что `account.api_key` —
это текст, а в таблице лежит `1:` и затем Base64 случайного nonce,
шифротекста AES-256-GCM и его тега. Два сохранения одного значения дают
разные шифротексты, поэтому по столбцу нельзя искать:

- `where`, `where_like`, `where_between`, `update_all`, `increment`,
  `upsert`, `uniqueness` и массовые записи его отвергают (`ArgumentError`); `pluck` отвечает
  шифротекстом.
- `to_json` и `as_json` включают расшифрованный текст, как в Rails; не
  выводите этот столбец на страницах.
- Пустое хранимое значение читается как `""`, так что столбец NOT NULL,
  добавленный с `default: "''"`, остаётся читаемым, пока его строки не
  сохранены заново.
- Недоступно: `deterministic: true` и чтение шифротекстов
  `ActiveRecord::Encryption` из Rails (там другие вывод ключа и формат).

### Ключи и их смена

Модель с `encrypts` заставляет приложение подключить openssl, и запуск
завершается ошибкой, если в `CYBERTRAIN_ENCRYPTION_KEY` нет 64
шестнадцатеричных символов (создайте ключ командой
`cybertrain secret --hex`; [переменные](configuration.md#configuration-and-environment-variables)).
Ключ не выводится из `CYBERTRAIN_SECRET_KEY_BASE`, так что смена секрета
сессий оставляет данные читаемыми; потеряете ключ шифрования — потеряете
данные. Чтобы сменить его, поместите новый ключ в `CYBERTRAIN_ENCRYPTION_KEY`,
а старый — в `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` (через запятую; пробуются
только для чтения), затем перезапишите каждую запись:

```ruby
Account.find_each { |account| account.update_columns(api_key: account.api_key) }
```

Код, который сам вызывает `Cybertrain::Crypto.encrypt(text)` /
`Crypto.decrypt(payload)` в приложении без `encrypts`, добавляет
`require "cybertrain/encryptor"` в `bin/<app>.rb` и задаёт ключ.

### Шифрование столбца, в котором уже есть текст

Строки, записанные до добавления `encrypts`, хранят открытый текст, и чтение
такой строки выбрасывает `Cybertrain::Encryptor::Error`. Зашифруйте их один
раз через SQL из команды приложения (`./<app> encrypt_api_keys`):

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

`NOT LIKE '1:%'` не даёт повторному запуску зашифровать шифротекст ещё раз;
уберите его, если открытые значения могут начинаться с `1:`. Значения,
зашифрованные Rails, сначала расшифровываются в приложении Rails, а затем
шифруются здесь тем же способом.

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
диапазоном `min..max`).

`relation.page(n, per: 50)` задаёт relation
`LIMIT per OFFSET (n - 1) * per` (заменяя прежние `limit`/`offset`, поэтому
вызывайте его последним), ограничивает `n` так же, поэтому смещение никогда не
превышает `(max_page - 1) * per`, и возвращает `Cybertrain::Page`: `number`,
`per`, `row_offset`, `next?` (определяется одним
`SELECT 1 ... LIMIT per + 1` по окну, без `COUNT(*)`), `prev?`,
`next_number`, `prev_number`. Строки остаются в relation, поэтому
`@articles.each` выдаёт типизированные `Article`; `per` вне 1..1000 — это
`ArgumentError`.

`paginate @page, path` выводит `<nav class="pager">` со ссылкой
«Newer» (`rel="prev"`), «Page N» и ссылкой «Older» (`rel="next"`); каждая
опускается, если такой страницы нет; ссылки сохраняют текущую строку запроса с
заменённым `page` (для страницы 1 он убирается), заново закодированную и
экранированную, поэтому поиск или фильтр сохраняются при листании, а путь с
собственной строкой запроса (`"/search?q=x"`) использует вместо этого её.

Только постраничный вывод по смещению: постраничный вывод по ключу (`after: id`)
для очень больших таблиц пока не реализован. Представление index из скаффолда
выводит все записи; чтобы разбить его на страницы, добавьте три строки выше.

## Транзакции

`Cybertrain::DB.transaction { |c| ... }` (или `Article.transaction` — то же
самое под именем из Rails) берёт соединение из пула, выполняет `BEGIN`, передаёт
соединение в блок, делает `COMMIT`, когда блок возвращается, и откатывает
транзакцию с повторным возбуждением исключения, когда блок его возбуждает.
`immediate: true` выполняет `BEGIN IMMEDIATE`, который захватывает блокировку
записи SQLite в самом начале: используйте его для транзакции, которая сначала
читает, а затем пишет, чтобы параллельный писатель заставил её ждать на `BEGIN`,
а не упасть с «database is locked» при первой записи. Пока выполняется блок, всё
в этом потоке, что идёт через пул (`save`, `update`, `destroy`, запросы Relation,
`DB.with`), использует соединение транзакции и, следовательно, входит в
транзакцию:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

Чем она отличается от `transaction` в Rails и чего следует избегать:

- Она возвращает nil, а не значение блока.
- Из неё выходят, возбуждая исключение, и после отката оно возбуждается повторно (в Rails выходят через `raise ActiveRecord::Rollback`).
- `DB.transaction`, вложенный в блок, присоединяется к внешней транзакции: фиксирует только самая внешняя, исключение в любом месте откатывает всё, а точек сохранения нет (нет `requires_new: true`).
- `c.transaction { }` нельзя вызвать на переданном `c` под Spinel: вкладывайте `DB.transaction` или используйте форму без блока ниже.
- `DB.transaction`, вызванный внутри блока `DB.with` (который транзакцией не является), берёт второе соединение: в пуле из одного соединения (включая `:memory:`) он после этого ждёт вечно. Сначала откройте транзакцию и выполняйте работу внутри неё.
- Не перехватывайте ошибку базы данных внутри блока, чтобы продолжить работу. После «database or disk is full», ошибки ввода-вывода или тайм-аута ожидания блокировки SQLite может сама откатить всю транзакцию. Тогда каждый следующий оператор в блоке возбуждает `Cybertrain::DB::Error` («the enclosing transaction is no longer open») вместо того, чтобы зафиксироваться сам по себе, а в конце блока исключение возбуждает и транзакция. Дайте ошибке выйти из блока и при необходимости повторите всю транзакцию. С транзакцией, открытой через `c.exec_script("BEGIN")`, обращаются так же, пока её не завершат `COMMIT`, `END` или `ROLLBACK`; `ROLLBACK` в этом случае ничего не делает и завершается успешно, потому что SQLite уже откатила транзакцию.

Код, который должен держать свой `rescue` в обычном методе, использует форму без
блока, `c.begin!(immediate: true)` ... `c.commit!`, с `c.rollback!` в rescue.

## Имена столбцов

Имя столбца должно быть идентификатором ASCII (`[A-Za-z_][A-Za-z0-9_]*`), тогда
как Rails принимает любое. Схема с не-ASCII именем столбца (`名前`, `prénom`)
генерировалась под CRuby до PR #10, а теперь `spin run gen` её отвергает, поэтому
при обновлении переименуйте столбец (имя вроде `first-name` никогда не было
именем метода).

Столбец, названный как метод, который сгенерированный класс или фреймворк
вызывает у записи (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`,
`raise`, ...), или как ключевое слово Ruby (`end`, `class`, `begin`),
генерируется под именем `<column>_column` (`hash_column`: читатель, писатель и
ivar) с примечанием в сгенерированном файле. Два его имени используются так:

- Его имя в SQL продолжает работать в `read_attribute`, params и `attributes["hash"]`.
- Шаблон достаёт его под любым из имён (`post.hash`, `post.hash_column`), кроме `errors` и `to_param`, которые шаблон разрешает как методы модели: там используйте `post.errors_column`.
- API запросов (`where`, `order`, `find_by`) всегда принимает имя столбца в SQL (`Post.where(hash: 1)`); имя в Ruby — это только читатель/писатель и имя в шаблоне.

Столбец, названный как другой метод Object (`display`, `tap`, `methods`),
генерируется под своим именем с примечанием. `cybertrain generate scaffold`
отвергает ключевые слова и зарезервированные имена (ему пришлось бы вызывать
переименованный читатель) и принимает затеняющее имя с примечанием, как и
генератор.

Ассоциация, чьё простое имя уже занято столбцом, другой ассоциацией или
методом `Model` (Rails позволяет затенить `errors`), выдаётся под запасным
именем с комментарием в сгенерированном файле: `<table>_as_<column stem>`
для `has_many` (`comments_as_article`), `<stem>_as_<column>` для `belongs_to`
(`author_as_author_id`).

## Двоичные столбцы

`t.binary` создаёт столбец `BLOB` для байтов, которые не являются текстом:
миниатюры, сжатого снимка, ключа. Атрибут — String, содержащая ровно
сохранённые байты, включая байты NUL и байты больше 127, либо `nil` для
`NULL` (столбец допускает NULL, если не объявлен `null: false`, так что у
фотографии, сохранённой до добавления столбца, миниатюры нет: проверьте
`nil` перед `bytesize`):

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
Photo.find(photo.id).thumbnail.bytesize   # те же байты обратно
```

- Сгенерированная модель при сохранении привязывает двоичный столбец как
  BLOB; любая другая String по-прежнему привязывается как TEXT, который
  обрывается на байте NUL. В сыром SQL оберните байты в
  `Cybertrain::DB::Blob.new(bytes)`, чтобы привязать их как BLOB
  (`c.execute("INSERT INTO photos (thumbnail) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`).
- Ячейка BLOB, прочитанная сырым SQL, — это String с её байтами;
  `Cybertrain::Cast.binary(value)` сужает её (`""` для `NULL`).
- `Photo.where(thumbnail: bytes)` тоже привязывает байты как BLOB (TEXT в
  привязке никогда не равен сохранённому BLOB).
- `db/schema.rb` записывает столбец обратно как `t.binary`, а консоль
  печатает двоичное значение как `<N bytes>`.
- Большие файлы держите вне базы: загрузка ([Добавить загрузку
  файла](tutorial.md#attachments)) — это файл в `storage/uploads/`, а BLOB
  читается в память целиком вместе со строкой и увеличивает каждую
  резервную копию и WAL.

## Порядок

Там, где `order` в Rails принимает любой SQL (`order("lower(title)")`,
`order("posts.title")`, `order(params[:sort])`), `order` здесь принимает только
списки `column [ASC|DESC]`, каждый столбец берётся в кавычки, и на всё остальное
возбуждает `ArgumentError`: это 500, поскольку строка принадлежит разработчику.

Данные запроса должны сначала пройти через список разрешённых значений, потому
что корректно оформленный терм всё равно может назвать отсутствующий столбец
(500 от SQLite) или столбец, по которому клиенту нельзя сортировать:

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

Сырой текст ORDER BY идёт через `order_sql` (`Post.order_sql("lower(title)")`,
также у relation), который никогда не должен видеть данных запроса.

## Перенос базы данных, созданной Rails

Файл SQLite, созданный приложением на Rails 8, читается как есть:

1. Скопируйте его по пути базы приложения, по умолчанию
   `storage/development.sqlite3` (`storage/<env>.sqlite3` или туда, куда
   указывает `CYBERTRAIN_DATABASE`).
2. Запустите `cybertrain db schema` (`./<app> db schema` для собранного
   бинарника). Команда пишет `db/schema.rb` по базе тем же дампером, что и
   `db migrate`, печатает `wrote .../db/schema.rb from <path>` и больше
   ничего не делает. После этого `cybertrain db migrate` не находит, что
   применять, и генерирует модели.
3. Не копируйте `db/migrate/*.rb` из Rails: новые миграции начинаются
   отсюда. У версий Rails, уже записанных в `schema_migrations` (у обоих одна
   и та же таблица), здесь нет файлов, поэтому мигратор их не выполняет и не
   откатывает, а `db status` показывает их как `applied (no file)`.
4. Что не требует преобразования: дата-время (формат Rails и есть хранимый),
   логические значения (`1` / `0` и старые `t` / `f`), десятичные числа (Rails
   пишет значения REAL; они читаются как Float), json (TEXT, читается как
   Hash) и имена типов, которые пишет Rails (`datetime(6)`, `decimal(18,8)`,
   `varchar`, `bigint`, `json`). Частичные индексы, индексы по выражениям и
   действия `ON DELETE` тоже выгружаются.
5. Ограничения: таблица, чей первичный ключ — не столбец `id` (таблица
   связей), выгружается как `create_table "articles_tags", id: false` и не
   получает модели (`spin run gen` печатает `skipped articles_tags: no id
   column`); обращайтесь к ней через `DB.with`; первичный ключ `id`, который
   не целое число (`id: :uuid` или `id: :string` в Rails), выгружается так
   же, а `id` остаётся обычным столбцом без PRIMARY KEY; `ar_internal_metadata`
   остаётся как есть; таблицу, в `CREATE TABLE` которой есть то, чего схема
   не моделирует, нельзя изменить перестраивающими помощниками ([Изменение
   таблицы](#changing-a-table)); столбцы, зашифрованные Rails, шифруются
   заново ([Шифрование столбца, в котором уже есть
   текст](#encrypting-a-column-that-already-holds-text)).

Затем напишите `app/models/*.rb` с валидациями, ассоциациями и скоупами,
которые были у моделей Rails, в формах, показанных на этой странице.

## Обновление с 0.4

Каждое изменение ниже — правка в один проход для приложения, написанного
для CyberTrain 0.4:

1. Метод чтения `has_many` возвращает relation, а не Array: добавьте `.to_a`
   перед методом, который есть только у Array (`map`, `select`, `[]`, `+`).
   Шаблоны не меняются.
2. Дата-время хранится в формате Rails: один раз после обновления запустите
   `db normalize` ([Дата-время и `db normalize`](#datetimes-and-db-normalize));
   до тех пор столбец со смесью двух форматов сортируется по формату.
3. `as_json` и `to_json` пишут время как `2026-10-05T09:00:00.000Z` (было
   `2026-10-05T09:00:00Z`): снапшоты JSON в тестах меняются.
4. Атрибут `t.date` — это `Date`, а не String: `strftime` по-прежнему
   работает, для конкатенации нужен `to_s`. Столбец даты NOT NULL теперь
   проверяет присутствие.
5. Объявленный `belongs_to` без `optional: true` проверяет свой внешний
   ключ; необъявленные не меняются.
6. `where(x: a..b)` с концами Integer — условие диапазона (раньше это было
   равенство с текстом Range, которое никогда не совпадало); границы Time и
   Date используют `where_between`.
7. `Cybertrain::Cast.iso8601` — формат отображения: код, который строил им
   текст SQL, переходит на `Cast.sql_datetime`, а `Cast.binds` привязывает
   Time в хранимом формате.
8. `allow_blank: true` в строке `validates` позволяет и `presence` этой
   строки пропускать пустое значение, как в Rails (раньше относилось только к
   `length`).
9. Столбец, названный как метод, который теперь есть у каждой модели
   (`update_columns`, `destroy_dependents`, `run_custom_validations`, ...),
   генерируется как `<column>_column` ([Имена столбцов](#column-names)).
10. Метод чтения `belongs_to` хранит прочитанного родителя, пока не
    изменится внешний ключ (раньше он читал его при каждом вызове): вызовите
    `reload`, чтобы увидеть изменение, сделанное другим процессом.
