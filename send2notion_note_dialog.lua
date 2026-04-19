-- send2notion_note_dialog.lua
--
-- Multi-line note composer used by both the tools menu entry and the
-- highlight-popup entry point. The gear icon at the top-left opens a quick
-- settings pop-up that lets the user switch targets without leaving the
-- compose screen, mirroring the UX of send2telegram.
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("send2notion_api")

local Screen = Device.screen

local NoteDialog = {}

-- ---------------------------------------------------------------------------
-- Book-context collection
-- ---------------------------------------------------------------------------

-- Pull title/author/page info out of the ReaderUI when available. Both
-- CRe (rolling) and paging documents expose the needed bits but through
-- slightly different paths; we try the most reliable source first and
-- swallow any unexpected failure so the note still goes out.
local function collectBookContext(plugin)
    local ctx = {}
    if not plugin.ui or not plugin.ui.document then return ctx end
    local props = plugin.ui.doc_props or {}
    local title = props.title
    if not title or title == "" then
        local filepath = plugin.ui.document.file
        if filepath then
            local filename = filepath:match("([^/\\]+)$") or filepath
            title = filename:match("(.+)%.[^%.]+$") or filename
        end
    end
    ctx.title = title
    ctx.author = props.authors

    local cur_page, total_page
    if plugin.ui.paging and plugin.ui.view and plugin.ui.view.state then
        cur_page = plugin.ui.view.state.page
    elseif plugin.ui.document.getCurrentPage then
        local ok, page = pcall(function() return plugin.ui.document:getCurrentPage() end)
        if ok then cur_page = page end
    end
    if plugin.ui.document.getPageCount then
        local ok, total = pcall(function() return plugin.ui.document:getPageCount() end)
        if ok then total_page = total end
    end
    ctx.cur_page = cur_page
    ctx.total_page = total_page
    return ctx
end

local function formatBookHeader(ctx)
    if not ctx.title or ctx.title == "" then return nil end
    local header
    if ctx.author and ctx.author ~= "" then
        header = T(_("%1 — %2"), ctx.title, ctx.author)
    else
        header = ctx.title
    end
    local page_info
    if ctx.cur_page and ctx.total_page then
        page_info = T(_(" · p.%1/%2"), ctx.cur_page, ctx.total_page)
    elseif ctx.cur_page then
        page_info = T(_(" · p.%1"), ctx.cur_page)
    end
    if page_info then header = header .. page_info end
    return header
end

-- ---------------------------------------------------------------------------
-- Sub-page title templating
-- ---------------------------------------------------------------------------

local function firstLineSnippet(text, max_len)
    if not text or text == "" then return "" end
    local first = text:match("^([^\r\n]*)") or text
    first = first:gsub("^%s+", ""):gsub("%s+$", "")
    if #first > (max_len or 60) then
        first = first:sub(1, max_len or 60) .. "…"
    end
    return first
end

local function formatSubpageTitle(template, ctx, note_text)
    local tpl = template
    if type(tpl) ~= "string" or tpl == "" then
        tpl = "%book% · %date% %time%"
    end
    local book = (ctx.title and ctx.title ~= "") and ctx.title or _("Note")
    local author = ctx.author or ""
    local date = os.date("%Y-%m-%d")
    local time = os.date("%H:%M")
    local note_snippet = firstLineSnippet(note_text or "", 60)

    local title = tpl
    title = title:gsub("%%book%%", function() return book end)
    title = title:gsub("%%author%%", function() return author end)
    title = title:gsub("%%date%%", function() return date end)
    title = title:gsub("%%time%%", function() return time end)
    title = title:gsub("%%note%%", function() return note_snippet end)
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then title = book end
    return title
end

-- ---------------------------------------------------------------------------
-- Block assembly
-- ---------------------------------------------------------------------------

-- Build the Notion block list that represents the user's note. Always
-- returns at least one block; callers may prepend/append extra blocks
-- (e.g. a divider) as needed.
local function buildBlocks(plugin, note_text, highlighted_text, ctx)
    local blocks = {}

    local include_ctx = plugin:readSetting("include_book_context", true)
    if include_ctx then
        local header = formatBookHeader(ctx)
        if header then
            table.insert(blocks, Api.headingBlock(header, 3))
        end
    end

    if highlighted_text and highlighted_text ~= "" then
        table.insert(blocks, Api.quoteBlock(highlighted_text))
    end

    if note_text and note_text ~= "" then
        table.insert(blocks, Api.paragraphBlock(note_text))
    end

    if #blocks == 0 then
        -- Should not happen (caller guards empty submissions) but keep a
        -- defensive fallback so the API never gets an empty children[].
        table.insert(blocks, Api.paragraphBlock(_("(empty note)")))
    end
    return blocks
end

-- ---------------------------------------------------------------------------
-- Actual send
-- ---------------------------------------------------------------------------

local function dispatchToTarget(target, blocks, subpage_title)
    local mode = target.mode or "append"
    if mode == "subpage" then
        return Api.createSubpage(target.token, target.page_id, subpage_title, blocks)
    end
    return Api.appendBlocks(target.token, target.page_id, blocks)
end

-- Fire-and-wait HTTP send, optionally deferred until the device is online.
-- Errors and successes are reported through UIManager notifications so the
-- user always gets feedback regardless of the code path taken.
local function sendToActiveTarget(plugin, note_text, highlighted_text)
    local target, label = plugin:getActiveTarget()
    if not target then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("No Notion target configured. Edit send2notion_configuration.lua first."),
            timeout = 5,
        })
        return
    end
    if not target.token or target.token == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Target '%1' is missing an integration token."), label),
            timeout = 5,
        })
        return
    end
    if not Api.normalizePageId(target.page_id) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Target '%1' has an invalid page id. Expected a 32-char hex id from the Notion URL."), label),
            timeout = 6,
        })
        return
    end

    local ctx = collectBookContext(plugin)
    local blocks = buildBlocks(plugin, note_text, highlighted_text, ctx)
    local subpage_title = formatSubpageTitle(target.subpage_title, ctx, note_text)

    local perform = function()
        Trapper:wrap(function()
            local trap = InfoMessage:new{
                text = T(_("Sending note to %1…"), label),
                timeout = nil,
            }
            UIManager:show(trap)
            local ok, err = dispatchToTarget(target, blocks, subpage_title)
            UIManager:close(trap)
            if ok then
                UIManager:show(Notification:new{
                    text = T(_("Sent to %1"), label),
                })
            else
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Failed to send to %1:\n%2"), label, err or _("Unknown error")),
                    timeout = 6,
                })
            end
        end)
    end

    if NetworkMgr:isOnline() then
        perform()
        return
    end

    UIManager:show(Notification:new{
        text = _("Offline — the note will be sent once online."),
    })
    NetworkMgr:runWhenOnline(perform)
end

-- Compute the dialog title. When the user defined a `name` for the
-- active target in configuration, it is shown verbatim; otherwise the
-- target key is used. This keeps the screen honest about which page
-- will receive the note.
local function buildDialogTitle(plugin)
    local _target, label = plugin:getActiveTarget()
    if label then
        return T(_("Send to %1"), label)
    end
    return _("Send to Notion")
end

-- Main entry point used by both the tools menu and the highlight popup.
-- `highlighted_text` is optional: when present the note is treated as a
-- free-form annotation above the quoted text, when absent the note
-- stands alone.
function NoteDialog.show(plugin, highlighted_text)
    local dialog
    local description
    if highlighted_text and highlighted_text ~= "" then
        local preview = highlighted_text
        if #preview > 240 then
            preview = preview:sub(1, 240) .. "…"
        end
        description = T(_("Add an optional comment. Highlighted text will be sent below.\n\n“%1”"), preview)
    else
        description = _("Write the note you want to send to your Notion page.")
    end

    dialog = InputDialog:new{
        title = buildDialogTitle(plugin),
        description = description,
        input = "",
        input_hint = _("Type your note here…"),
        input_type = "text",
        allow_newline = true,
        input_multiline = true,
        input_height = 6,
        text_height = math.floor(10 * Screen:scaleBySize(20)),
        width = math.floor(Screen:getWidth() * 0.85),
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function()
            -- Close the virtual keyboard first so the quick-settings
            -- pop-up can be dismissed without the keyboard staying on
            -- screen.
            if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
            plugin:showQuickSettings(function()
                -- Refresh the title so a target switch is visible
                -- without re-opening the note screen.
                if dialog and dialog.title_bar then
                    dialog.title = buildDialogTitle(plugin)
                    dialog.title_bar:setTitle(dialog.title)
                end
            end)
        end,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Send"),
                is_enter_default = true,
                callback = function()
                    local note_text = dialog:getInputText() or ""
                    note_text = note_text:gsub("^%s+", ""):gsub("%s+$", "")
                    local has_highlight = highlighted_text and highlighted_text ~= ""
                    if note_text == "" and not has_highlight then
                        UIManager:show(InfoMessage:new{
                            text = _("Nothing to send. Type a note or select some text first."),
                            timeout = 3,
                        })
                        return
                    end
                    UIManager:close(dialog)
                    sendToActiveTarget(plugin, note_text, highlighted_text)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return NoteDialog
