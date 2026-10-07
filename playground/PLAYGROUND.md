# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below, and the app opens in
a new browser tab when the server is ready. The app does not show inside VS Code:
use that browser tab.

The page does not reload by itself: after a change, reload its tab.

## If the app's tab did not open

A pop-up blocker may stop the app's tab: Chrome then shows a "Pop-up blocked" icon
at the right end of the address bar. Allowing pop-ups there does not open the tab
afterwards, so open it yourself, in any of these ways. Each is a click, so no
pop-up blocker stops it.

- **VS Code's notification**: "Your application (cybertrain) running on port 3000
  is available." → **Open in Browser**. If the notification has gone, the bell
  icon at the right end of the status bar (bottom right) keeps it.
- **The Ports view**: the **PORTS** tab next to **TERMINAL** → the row for port
  3000 (`cybertrain`) → the globe icon (**Open in Browser**), or right-click the
  row → **Open in Browser**.
- **The terminal**: in the `server` terminal, Ctrl-click (Cmd-click on a Mac) the
  `https://…-3000.app.github.dev/` link after `App`.

These also open the app again after you closed its tab, or after the codespace was
stopped and restarted.

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
- This guide opens as a Markdown preview. To edit it as text, right-click its
  tab → "Reopen Editor With..." → "Text Editor".
- When you are done, delete the codespace at https://github.com/codespaces: its
  storage counts against your quota for as long as it exists.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
