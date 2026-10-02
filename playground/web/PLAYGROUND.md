# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the preview shows
the app.

This session ends at the time the terminal shows, and everything in it is deleted
then. To keep a file or a folder, right-click it in the Explorer and choose Download.

The preview does not reload by itself: after a change, press its reload button.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the preview. Views are read from disk on every request, so there is
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

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
- The session has no network: `gem install`, `curl` to the internet and `git push`
  do not work. Only port 3000 can be previewed.
- Anyone with this page's address can use this session, terminal included: do not
  share it. The preview's address shows only the app.
- Closing the tab ends the session a few minutes later.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
