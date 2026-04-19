-- send2notion_settings.lua
--
-- Builds the settings user interface. Two entry points are exposed:
--   * `Settings.showQuickSwitch` : small pop-up opened from the gear icon
--     on the note screen. Lets the user pick the active target with one
--     tap and toggle the most commonly used options.
--   * `Settings.buildMenu`       : list of menu entries injected into the
--     plugin's main menu under Tools.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = {}

-- ---------------------------------------------------------------------------
-- Quick-switch pop-up (gear icon inside the note dialog)
-- ---------------------------------------------------------------------------

local function buildTargetRadioRows(plugin, on_selected)
    local targets = plugin:getConfiguredTargets()
    local active_id = plugin:getActiveTargetId()
    local rows = {}
    if #targets == 0 then
        table.insert(rows, { {
            text = _("No targets configured"),
            background = Blitbuffer.COLOR_WHITE,
            enabled = false,
            callback = function() end,
        } })
        return rows
    end
    for _, entry in ipairs(targets) do
        local marker = entry.id == active_id and "◉ " or "○ "
        local row = { {
            text = marker .. entry.label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                plugin:setActiveTargetId(entry.id)
                if on_selected then on_selected() end
            end,
        } }
        table.insert(rows, row)
    end
    return rows
end

function Settings.showQuickSwitch(plugin, refresh_callback)
    local dialog
    local buttons = {}

    -- Header row: information only.
    table.insert(buttons, { {
        text = _("Switch active target"),
        background = Blitbuffer.COLOR_WHITE,
        enabled = false,
        callback = function() end,
    } })

    local target_rows = buildTargetRadioRows(plugin, function()
        UIManager:close(dialog)
        if refresh_callback then refresh_callback() end
    end)
    for _, row in ipairs(target_rows) do
        table.insert(buttons, row)
    end

    -- Toggles row.
    local include_ctx = plugin:readSetting("include_book_context", true)
    table.insert(buttons, { {
        text = include_ctx and _("✓ Include book title/page") or _("☐ Include book title/page"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            plugin:saveSetting("include_book_context", not include_ctx)
            UIManager:close(dialog)
            Settings.showQuickSwitch(plugin, refresh_callback)
        end,
    } })

    local hl_enabled = plugin:readSetting("highlight_button_enabled", true)
    table.insert(buttons, { {
        text = hl_enabled and _("✓ Show button in highlight menu") or _("☐ Show button in highlight menu"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            plugin:saveSetting("highlight_button_enabled", not hl_enabled)
            plugin:refreshHighlightButton()
            UIManager:close(dialog)
            Settings.showQuickSwitch(plugin, refresh_callback)
        end,
    } })

    -- Full settings launcher.
    table.insert(buttons, { {
        text = _("Test connection"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            UIManager:close(dialog)
            Settings.testActiveTarget(plugin)
        end,
    } })

    table.insert(buttons, { {
        text = _("Close"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function() UIManager:close(dialog) end,
    } })

    dialog = ButtonDialog:new{
        title = _("Send to Notion · quick settings"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Main menu entries
-- ---------------------------------------------------------------------------

-- Validate the active target's token *and* page reachability. Run both
-- checks so the user sees the first failing step instead of a vague
-- "cannot reach Notion".
function Settings.testActiveTarget(plugin)
    local target, label = plugin:getActiveTarget()
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("No active target. Edit send2notion_configuration.lua first."),
            timeout = 4,
        })
        return
    end
    Trapper:wrap(function()
        local trap = InfoMessage:new{
            text = T(_("Contacting Notion as %1…"), label),
            timeout = nil,
        }
        UIManager:show(trap)
        local Api = require("send2notion_api")
        local ok, info = Api.whoAmI(target.token)
        if not ok then
            UIManager:close(trap)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Could not reach Notion:\n%1"), info or _("unknown error")),
                timeout = 6,
            })
            return
        end
        -- Token works; now make sure the configured page is reachable.
        local ok_page, err_page = Api.getPage(target.token, target.page_id)
        UIManager:close(trap)
        if ok_page then
            UIManager:show(InfoMessage:new{
                text = T(_("Connected as integration '%1'.\nTarget page is reachable."), info),
                timeout = 4,
            })
        else
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Token works but the target page is not reachable:\n%1\n\nMake sure you invited the integration to the page (Share → Invite)."),
                    err_page or _("unknown error")),
                timeout = 8,
            })
        end
    end)
end

-- Build the sub_item_table shown under the main menu entry.
function Settings.buildMenu(plugin)
    local items = {}

    table.insert(items, {
        text_func = function()
            local _target, label = plugin:getActiveTarget()
            if label then
                return T(_("Active target: %1"), label)
            end
            return _("Active target: (none)")
        end,
        sub_item_table_func = function()
            local sub = {}
            local targets = plugin:getConfiguredTargets()
            if #targets == 0 then
                table.insert(sub, {
                    text = _("No targets configured. Edit send2notion_configuration.lua."),
                    enabled = false,
                })
                return sub
            end
            for _, entry in ipairs(targets) do
                local target_id = entry.id
                local target_label = entry.label
                table.insert(sub, {
                    text_func = function()
                        local is_active = plugin:getActiveTargetId() == target_id
                        return (is_active and "◉ " or "○ ") .. target_label
                    end,
                    callback = function(touchmenu_instance)
                        plugin:setActiveTargetId(target_id)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                    keep_menu_open = true,
                })
            end
            return sub
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text_func = function()
            local on = plugin:readSetting("highlight_button_enabled", true)
            return on and _("Show button in highlight menu: on")
                or _("Show button in highlight menu: off")
        end,
        callback = function(touchmenu_instance)
            local cur = plugin:readSetting("highlight_button_enabled", true)
            plugin:saveSetting("highlight_button_enabled", not cur)
            plugin:refreshHighlightButton()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text_func = function()
            local on = plugin:readSetting("include_book_context", true)
            return on and _("Append book title/page: on")
                or _("Append book title/page: off")
        end,
        callback = function(touchmenu_instance)
            local cur = plugin:readSetting("include_book_context", true)
            plugin:saveSetting("include_book_context", not cur)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Test active target connection"),
        callback = function() Settings.testActiveTarget(plugin) end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Reset remembered settings"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Reset the active-target selection and toggles? This does not change your configuration file."),
                ok_text = _("Reset"),
                ok_callback = function()
                    plugin:resetRememberedSettings()
                    UIManager:show(Notification:new{ text = _("Settings reset.") })
                end,
            })
        end,
        keep_menu_open = true,
        separator = true,
    })

    table.insert(items, {
        text = _("About Send to Notion"),
        callback = function()
            local _target, label = plugin:getActiveTarget()
            local lines = {
                _("Send to Notion"),
                "",
                plugin:isConfigured()
                    and T(_("Active target: %1"), label or _("(none)"))
                    or _("send2notion_configuration.lua not found."),
                "",
                _("Copy send2notion_configuration.sample.lua to send2notion_configuration.lua inside the plugin folder and add your integration token and target page id. Remember to invite the integration to the page from Notion (Share → Invite). Then return here."),
            }
            UIManager:show(InfoMessage:new{
                text = table.concat(lines, "\n"),
                timeout = 10,
            })
        end,
        keep_menu_open = true,
    })

    return items
end

return Settings
