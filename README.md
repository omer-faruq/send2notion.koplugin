# Send to Notion

Send quick notes and book highlights from KOReader directly to a page in
your Notion workspace. The plugin adds two entry points:

- a single **Send note to Notion** item under the *Tools* menu, which
  opens a small writing screen, and
- an optional **Send to Notion** button inside the highlight popup, so
  that any selected book text can be shipped to your page with an
  optional comment.

Multiple targets can be declared in the configuration file, the active
one is picked from the gear icon on the writing screen, and messages
that are composed while Wi-Fi is off are held and flushed automatically
as soon as the device comes online again.

---

## 1. Create a Notion integration

Notion's public API authenticates with an *internal integration token*.
You create one per workspace, from your browser.

1. Open <https://www.notion.so/my-integrations> in a browser and log in
   with the account that owns the workspace you want to write to.
2. Click **+ New integration**.
3. Pick a name (e.g. *KOReader notes*), choose the workspace, and make
   sure the **Read content** / **Insert content** / **Update content**
   capabilities are enabled. *User information* and database access are
   not needed.
4. After creating it, open the integration's *Configuration* tab and
   copy the **Internal Integration Secret**. It starts with `secret_`
   or `ntn_`. Keep it private: anyone who has it can write to any page
   you give the integration access to.

> Tip: you can create several integrations. The plugin lets you map
> different targets to different integrations, which is handy when
> you want to route notes to separate workspaces.

---

## 2. Prepare the target page and share it with the integration

The plugin never creates top-level pages on its own. You decide which
Notion page will receive the notes.

1. In Notion, create (or pick) the page that should collect the notes.
   Any regular page works — a whole sub-page inside your workspace, a
   dedicated reading journal, a "Book club" page, etc.
2. Open that page, click **Share** in the upper-right corner, then
   **Invite**.
3. Start typing the name of your integration, select it, and confirm.
   The integration now has permission to read and write only this page
   and any of its descendants.

### Find the page id

The plugin needs the page's id, which is the 32-character hexadecimal
string at the end of the page URL.

Example URL:

```
https://www.notion.so/My-Reading-Notes-abcd1234efgh5678ijkl9012mnop3456
```

→ the page id is `abcd1234efgh5678ijkl9012mnop3456` (dashes are
optional, both forms are accepted by the plugin).

---

## 3. Configure the plugin

The plugin reads its configuration from a Lua file inside the plugin
folder. You only edit it once, from your PC.

1. On the reader, open **Tools → Send note to Notion** *once*. This
   makes sure the plugin folder is discovered.
2. On your computer, copy
   `send2notion_configuration.sample.lua` to
   `send2notion_configuration.lua` in the same folder.
3. Open the copy in any text editor and replace the placeholders with
   your own values:

   ```lua
   local CONFIGURATION = {
       default_target = "personal",

       targets = {
           personal = {
               name    = "Reading notes",
               token   = "secret_REPLACEWITHYOURNOTIONINTEGRATIONTOKEN",
               page_id = "abcd1234efgh5678ijkl9012mnop3456",
               mode    = "append",
           },
       },
   }

   return CONFIGURATION
   ```

4. Save and copy the file back to the reader (the plugin folder is
   `koreader/plugins/send2notion.koplugin/`).

### Multiple targets

You can define as many targets as you want under the
`targets = { ... }` table. Each entry has its own token and `page_id`.
The active target is the one named in `default_target` (or the first
one defined if that key is missing); you can switch targets at any
time from the gear icon on the note screen, or from *Tools → Send note
to Notion → Settings*.

Use this to route notes for different purposes to different pages —
for example a personal "scratch pad" page and a shared "book club"
page, even across different workspaces.

### Append vs sub-page mode

Each target entry may declare a `mode` field:

- `"append"` (default): every note is added as new blocks at the
  bottom of the target page. The page becomes a running journal.
- `"subpage"`: every note creates a new sub-page under the target
  page. Useful when you want each highlight to live in its own page
  so it can be linked to, tagged or moved around.

In sub-page mode the page title is built from the optional
`subpage_title` template. Supported placeholders:

| Placeholder | Replaced with                          |
|-------------|----------------------------------------|
| `%book%`    | current book title (or "Note" if none) |
| `%author%`  | author name (empty if missing)         |
| `%date%`    | current date (YYYY-MM-DD)              |
| `%time%`    | current time (HH:MM)                   |
| `%note%`    | first line of the note (up to 60 chars)|

Default template: `"%book% · %date% %time%"`.

> Can the plugin create the *target* page itself if it doesn't exist?
> No. Notion only lets integrations create pages as children of an
> existing page they already have access to. That's why you need to
> prepare the target page in step 2 and invite the integration to it
> once. After that, `"subpage"` mode *can* create arbitrarily many
> sub-pages below it without further setup.

---

## 4. Using the plugin

### Send a free-form note

*Tools → Send note to Notion* opens a small writing screen titled
after the active target ("Send to Reading notes"). Type the note and
tap **Send**. If the reader is offline you get a one-line notice that
the note is queued, and it will leave as soon as the device
reconnects.

### Send a book excerpt

1. Select text in the book as you usually would.
2. In the highlight popup, tap **Send to Notion**.
3. A writing screen opens with the quoted excerpt shown above the
   input box. Optionally type a comment.
4. Tap **Send**.

In `"append"` mode the page grows with:

```
Book title — Author · p.42/320      (heading, optional)

“<quoted excerpt>”                   (quote block, when present)

your comment                         (paragraph)
```

In `"subpage"` mode the same three blocks land inside a newly created
child page whose title follows the `subpage_title` template.

The book header can be turned off from the gear icon (*"Include book
title/page"*) for users who prefer to keep the note minimal.

### Quick-switch targets

On the writing screen, tap the gear icon at the top-left corner. A
small pop-up shows every target configured in
`send2notion_configuration.lua`; tap one to make it active. The title
of the note screen updates immediately, so you always know which page
is going to receive the message.

### Hide the highlight button

If you do not like the extra entry in the highlight popup:

- either open *Tools → Send note to Notion → Settings* and toggle
  **Show button in highlight menu** off,
- or use the same toggle from the gear icon's quick-settings screen.

The setting takes effect immediately.

### Test a target

*Tools → Send note to Notion → Settings → Test active target
connection* first verifies the token (`GET /v1/users/me`) and then
tries to read the configured page (`GET /v1/pages/{id}`). Use this
after editing the config file to make sure both the token is valid
**and** the integration has been invited to the page before you try
to send a real note.

---

## Troubleshooting

| Symptom                                                         | Likely cause                                                                  |
|-----------------------------------------------------------------|-------------------------------------------------------------------------------|
| `Notion API error (unauthorized): API token is invalid.`        | Token wrong, regenerated in the integration settings, or missing.             |
| `Notion API error (object_not_found): Could not find page ...` | Page id wrong, or the integration has not been invited to that page.          |
| `Notion API error (restricted_resource): ...`                   | The integration does not have the capability this request needs (enable write).|
| `Invalid Notion page id (expected 32 hex chars)`                | `page_id` is malformed; copy it again from the page URL.                      |
| `Network error: ...`                                            | No Internet connection, or `api.notion.com` is unreachable.                   |
| `Offline — the note will be sent once online.`                  | Expected. The note is queued and leaves once Wi-Fi is back.                   |

If a note should have been sent but never shows up:

1. Check the active target via the gear icon — it might be pointing at
   a different Notion page than you expected.
2. Re-run *Settings → Test active target connection*. A failure there
   means the problem is with the configuration file or with the
   integration's page access, not with the plugin.

---

## Files

| File                                    | Purpose                                           |
|-----------------------------------------|---------------------------------------------------|
| `main.lua`                              | Plugin entry point, menu and highlight wiring.    |
| `_meta.lua`                             | Plugin metadata (name, description, version).     |
| `send2notion_configuration.sample.lua`  | Copy this to `send2notion_configuration.lua`.     |
| `send2notion_configuration.lua`         | Your private config (not shipped).                |
| `send2notion_api.lua`                   | Notion REST API HTTP client.                      |
| `send2notion_note_dialog.lua`           | Note composer widget and block builder.           |
| `send2notion_settings.lua`              | Settings menu and quick-settings pop-up.          |

## Credits
This project was created with assistance from Windsurf (AI).
