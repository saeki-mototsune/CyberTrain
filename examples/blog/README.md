# Blog

The cybertrain acceptance app: the blog from the Rails Guides' "Getting
Started" (articles with comments), compiled to one binary by Spinel.

It was made with the CLI and then edited the way the guide edits it:

```sh
cybertrain new blog
cybertrain generate scaffold article title:string body:text
cybertrain generate scaffold comment commenter:string body:text article:references
```

- `config/routes.rb`: `root "articles#index"` and comments nested under
  articles (`only: [:create, :destroy]`); the standalone comment pages the
  scaffold wrote are gone.
- `Article` validates the title and a body of at least 10 characters, and
  deletes its comments before it is destroyed. `Article#comments` and
  `Comment#article` are generated from the `comments.article_id` foreign key.
- `articles/show.html.erb` lists the comments (`comments/_comment`) and
  ends with the comment form (`comments/_form`,
  `form_with(model: [@article, @comment])`).

```sh
cybertrain db migrate  # spin run gen; spin run db -- migrate; spin run gen
cybertrain server      # http://127.0.0.1:3000 (`cybertrain server 4000`, or PORT=4000, to change it)
cybertrain build       # dist/blog (views embedded) + dist/public/
spin test              # test/articles.rb, test/comments.rb against storage/test.sqlite3
```

Run `spin run gen` after changing the schema, the routes or a
controller's instance variables and callbacks, and commit `gen/`
(`spin run gen -- --check` reports stale files). Views under
`app/views/` are read at run time: edit them without rebuilding. A
production binary (`cybertrain build`, or `CYBERTRAIN_ENV=production`)
renders only the views embedded at build time.
