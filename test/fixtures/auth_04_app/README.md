# Shop

A cybertrain application, compiled to one binary by Spinel.

```sh
cybertrain generate scaffold post title:string body:text
cybertrain db migrate  # gen, apply db/migrate, gen again
cybertrain server      # http://127.0.0.1:3000 (`cybertrain server 4000` for another port)
cybertrain build       # dist/: the binary (views embedded) + public/
```

`spin run gen` (which `db`, `server` and `build` run for you)
regenerates `gen/` from db/schema.rb, config/routes.rb and app/;
commit `gen/`. In development views under `app/views/` are read at
run time: edit them without rebuilding. `cybertrain db status` and
`cybertrain db rollback 1` reach the other database commands.
`cybertrain db migrate` runs migrations through `bin/db.rb`; a
deployed `dist/shop` runs them with `./shop migrate`.

To deploy, copy `dist/` to a machine with the same OS and CPU, then
`cd dist && ./shop migrate && ./shop` (production by default;
set CYBERTRAIN_SECRET_KEY_BASE).

Or deploy with [Kamal](https://kamal-deploy.org): fill in the values
marked CHANGE ME in `config/deploy.yml`, export
KAMAL_REGISTRY_PASSWORD and CYBERTRAIN_SECRET_KEY_BASE (read by
`.kamal/secrets`), commit, then `kamal setup` once and `kamal deploy`
after that. The `Dockerfile` builds the binary inside the image.

On GitHub, `.github/workflows/ci.yml` installs the toolchain the
framework commit in `spin.lock` pins and checks that `spin.lock` and
`gen/` are committed and current, then runs `spin test`.
