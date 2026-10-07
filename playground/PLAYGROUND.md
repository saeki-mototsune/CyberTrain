# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the app opened in a
new browser tab (if it did not, use the Ports view's "Open in Browser" on port 3000).

The page does not reload by itself: after a change, reload its tab.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the app's tab. Views are read from disk on every request, so there is
   nothing to build.
2. **Add a validation.** In `app/models/article.rb`, add this line inside the class
   and save:

   ```ruby
   validates :body, presence: true, length: { minimum: 10 }
   ```

   Ruby is compiled, so the terminal shows a rebuild. After about a minute the
   server restarts by itself: an article with a short body now fails with "Body is
   too short (minimum is 10 characters)". If a change does not compile, the previous
   build keeps serving and every page shows the compiler's message at the top.
3. **Carry on with the tutorial** from step 08, "Scaffold comments":
   https://saeki-mototsune.github.io/CyberTrain/tutorial.html#scaffold-comment
   Stop the server first (Ctrl-C in its terminal), run the step's commands in a new
   terminal, then start it again with `cybertrain server`.

The Source Control view shows what you changed: the app is a git repository with
one commit.

## Start a fresh app

```sh
cd ..
cybertrain new shop && cd shop
cybertrain g scaffold product name:string
cybertrain db migrate
cybertrain server
```

Stop the blog's server first: both use port 3000. `cybertrain new` needs no network
here, and the first `cybertrain server` of a new app compiles it (about a minute).
The new app has no root route, so `/` shows "Not Found": its pages start at
`/products`.

## Good to know

- If VS Code asks whether you trust the authors of the files in this folder, choose
  "Trust Folder & Continue": the server's terminal starts only then.
- If the app's tab did not open (a pop-up blocker), use the Ports view's
  "Open in Browser" on port 3000. After the app's tab has opened, the Ports
  view's "Preview in Editor" on port 3000 also shows the app inside VS Code.
- When you are done, delete the codespace at https://github.com/codespaces: its
  storage counts against your quota for as long as it exists.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
