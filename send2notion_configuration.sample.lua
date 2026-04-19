-- Send to Notion configuration
--
-- Copy this file to `send2notion_configuration.lua` in the same folder and
-- fill in your Notion integration token(s) and target page id(s). You can
-- define as many "targets" as you like; the active one is chosen from the
-- settings menu or from the gear icon inside the note screen.
--
-- For every target:
--   token    : Notion integration secret. Create one at
--              https://www.notion.so/my-integrations and copy the
--              "Internal Integration Secret" (starts with "secret_" or
--              "ntn_"). The integration must be invited to the target
--              page (Share → Invite → select your integration).
--   page_id  : UUID of the target page. You can copy it from the page
--              URL: the 32-char hex string at the end (dashes are
--              optional, both formats are accepted).
--              Example URL: https://www.notion.so/My-Notes-abcd1234...ef
--              page_id    : "abcd1234...ef"
--   name     : friendly label shown in menus and on the note screen. When
--              omitted the target key ("personal" below) is used instead.
--   mode     : optional, one of:
--                "append"  (default) → each note is appended as new
--                                      blocks at the bottom of the page.
--                "subpage" → each note creates a new sub-page under the
--                            target page. Useful when you want one page
--                            per highlight/note.
--   subpage_title : optional template for the sub-page title when
--                   mode = "subpage". Supported placeholders:
--                     %book%   → current book title (or "Note" if none)
--                     %author% → author (empty if missing)
--                     %date%   → YYYY-MM-DD
--                     %time%   → HH:MM
--                     %note%   → first line of the note (up to 60 chars)
--                   Default: "%book% · %date% %time%".
--
-- The `default_target` key controls which target is selected before the
-- user has chosen one manually. If it is missing or invalid, the first
-- target in the table is used.
--
-- IMPORTANT: you must invite the integration to every target page from
-- inside Notion, otherwise the API answers with "object_not_found".

local CONFIGURATION = {
    default_target = "personal",

    targets = {
        personal = {
            name    = "Reading notes",
            token   = "secret_REPLACEWITHYOURNOTIONINTEGRATIONTOKEN",
            page_id = "00000000000000000000000000000000",
            mode    = "append",
        },

        -- Example: a second target that creates one sub-page per note.
        -- Useful if you want every highlight to become its own Notion
        -- page (handy for later tagging/linking from databases).
        -- bookclub = {
        --     name          = "Book club",
        --     token         = "secret_...",
        --     page_id       = "11111111111111111111111111111111",
        --     mode          = "subpage",
        --     subpage_title = "%book% · %date%",
        -- },

        -- Example: a third target that uses a different integration
        -- (different Notion workspace). Switch to it from the gear icon.
        -- work = {
        --     name    = "Work journal",
        --     token   = "secret_...",
        --     page_id = "22222222222222222222222222222222",
        --     mode    = "append",
        -- },
    },
}

return CONFIGURATION
