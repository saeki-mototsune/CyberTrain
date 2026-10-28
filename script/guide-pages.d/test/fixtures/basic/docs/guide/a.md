---
title: Alpha guide
nav: guides
---

# Alpha

Intro paragraph with a [link](b.md#top) and a ref [r][ref].

<!-- step 05 #validations stage: You write · `app/models/` -->
## Validations

> [!WHY]
> Because.

```ruby app/models/article.rb
# ## not a heading
class Article; end
```

```shell
bundle install
```

### Sub section

> [!NOTE]
> A note.

<!-- list: checklist -->
- one
- two

## Compare

<!-- table: cmp -->
| A | B |
|---|---|
| 1 | 2 |
| 3 | 4 |

<details><summary>Title — summary</summary>

Inner <a href="https://example.com/x">anchor</a>.

</details>

> [!RULE]
> ### Rule title
> Body.

## Querying beyond `where`

Text.

[ref]: c.md
