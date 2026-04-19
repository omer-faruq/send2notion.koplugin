-- send2notion plugin entry point.
--
-- Responsibilities:
--   * Load the optional send2notion_configuration.lua file that holds
--     integration tokens and target page ids.
--   * Add a single "Send note to Notion" entry to the tools menu.
--   * Optionally inject a button into the highlight pop-up that lets the
--     user send the selected text (plus a note) to the active target.
--   * Expose helpers used by the UI modules: active-target lookup,
--     settings read/write, quick-settings pop-up and highlight button
--     refresh.
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local NoteDialog = require("send2notion_note_dialog")
local SettingsModule = require("send2notion_settings")

-- ---------------------------------------------------------------------------
-- Configuration loading
-- ---------------------------------------------------------------------------

local PLUGIN_NAME = "send2notion"
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/" .. PLUGIN_NAME .. ".koplugin/"
local CONFIG_FILE_PATH = PLUGIN_DIR .. "send2notion_configuration.lua"
local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/send2notion.lua"
local HIGHLIGHT_BUTTON_ID = "send2notion"

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function loadConfigurationFile()
    if not fileExists(CONFIG_FILE_PATH) then
        return nil, nil
    end
    local ok, result = pcall(function() return dofile(CONFIG_FILE_PATH) end)
    if not ok then
        logger.warn("send2notion: configuration load failed:", result)
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "send2notion_configuration.lua did not return a table."
    end
    return result, nil
end

local CONFIGURATION, CONFIG_ERROR = loadConfigurationFile()

-- ---------------------------------------------------------------------------
-- Plugin definition
-- ---------------------------------------------------------------------------

local Send2Notion = InputContainer:extend{
    name = PLUGIN_NAME,
    is_doc_only = false,
    settings = nil,
    CONFIGURATION = nil,
}

function Send2Notion:readSetting(key, default)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    local val = self.settings:readSetting(key)
    if val == nil then return default end
    return val
end

function Send2Notion:saveSetting(key, value)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Send2Notion:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

function Send2Notion:resetRememberedSettings()
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:reset({})
    self.settings:flush()
    self:refreshHighlightButton()
end

function Send2Notion:isConfigured()
    return self.CONFIGURATION ~= nil
end

-- ---------------------------------------------------------------------------
-- Target resolution
-- ---------------------------------------------------------------------------

-- Return a stable array of { id = "key", label = "name or key", target = <cfg> }.
-- The order mirrors `configuration.target_order` if present; otherwise the
-- keys are sorted alphabetically so the UI stays deterministic across
-- reloads. For backward-friendliness we also honour `bots`/`bot_order`
-- keys if someone adapted a send2telegram config, but `targets` is the
-- documented name.
function Send2Notion:getConfiguredTargets()
    if not self.CONFIGURATION then return {} end
    local targets = self.CONFIGURATION.targets
    if type(targets) ~= "table" then return {} end
    local order = self.CONFIGURATION.target_order
    local seen = {}
    local result = {}

    local function append(key)
        if seen[key] or type(targets[key]) ~= "table" then return end
        seen[key] = true
        local target = targets[key]
        local label = (type(target.name) == "string" and target.name ~= "") and target.name or key
        table.insert(result, { id = key, label = label, target = target })
    end

    if type(order) == "table" then
        for _, key in ipairs(order) do append(key) end
    end
    local remaining = {}
    for key in pairs(targets) do
        if not seen[key] then table.insert(remaining, key) end
    end
    table.sort(remaining)
    for _, key in ipairs(remaining) do append(key) end
    return result
end

function Send2Notion:getDefaultTargetId()
    if not self.CONFIGURATION then return nil end
    local default = self.CONFIGURATION.default_target
    if default and type(self.CONFIGURATION.targets) == "table"
        and type(self.CONFIGURATION.targets[default]) == "table" then
        return default
    end
    local configured = self:getConfiguredTargets()
    if #configured > 0 then return configured[1].id end
    return nil
end

function Send2Notion:getActiveTargetId()
    local stored = self:readSetting("active_target_id")
    if stored and self.CONFIGURATION
        and type(self.CONFIGURATION.targets) == "table"
        and type(self.CONFIGURATION.targets[stored]) == "table" then
        return stored
    end
    return self:getDefaultTargetId()
end

function Send2Notion:setActiveTargetId(target_id)
    if not target_id then return end
    self:saveSetting("active_target_id", target_id)
end

-- Returns the active target config and its display label. Both are `nil`
-- when the plugin is not configured at all.
function Send2Notion:getActiveTarget()
    local id = self:getActiveTargetId()
    if not id or not self.CONFIGURATION then return nil, nil end
    local target = self.CONFIGURATION.targets and self.CONFIGURATION.targets[id]
    if type(target) ~= "table" then return nil, nil end
    local label = (type(target.name) == "string" and target.name ~= "") and target.name or id
    return target, label
end

-- ---------------------------------------------------------------------------
-- UI wiring
-- ---------------------------------------------------------------------------

function Send2Notion:ensureConfigured()
    if self:isConfigured() then return true end
    local lines = { _("Send to Notion is not configured yet.") }
    if CONFIG_ERROR then
        table.insert(lines, "")
        table.insert(lines, CONFIG_ERROR)
    end
    table.insert(lines, "")
    table.insert(lines, _("Copy send2notion_configuration.sample.lua to send2notion_configuration.lua in the plugin folder and fill in your integration token and target page id. See README.md for a step-by-step guide."))
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = table.concat(lines, "\n"),
        timeout = 8,
    })
    return false
end

function Send2Notion:openNoteDialog(highlighted_text)
    if not self:ensureConfigured() then return end
    NoteDialog.show(self, highlighted_text)
end

function Send2Notion:showQuickSettings(refresh_callback)
    SettingsModule.showQuickSwitch(self, refresh_callback)
end

-- ---------------------------------------------------------------------------
-- Highlight button lifecycle
-- ---------------------------------------------------------------------------

function Send2Notion:registerHighlightButton()
    if not self.ui or not self.ui.highlight or not self.ui.highlight.addToHighlightDialog then
        return
    end
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_BUTTON_ID, function(reader_highlight)
        return {
            text = _("Send to Notion"),
            callback = function()
                local selected = reader_highlight and reader_highlight.selected_text
                local text = selected and selected.text or ""
                if reader_highlight and reader_highlight.highlight_dialog then
                    UIManager:close(reader_highlight.highlight_dialog)
                    reader_highlight.highlight_dialog = nil
                end
                if reader_highlight and reader_highlight.clear then
                    reader_highlight:clear()
                end
                self:openNoteDialog(text)
            end,
        }
    end)
end

function Send2Notion:unregisterHighlightButton()
    if self.ui and self.ui.highlight and self.ui.highlight.removeFromHighlightDialog then
        self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_BUTTON_ID)
    end
end

function Send2Notion:refreshHighlightButton()
    if not self.ui or not self.ui.highlight then return end
    local wants = self:readSetting("highlight_button_enabled", true)
    if wants then
        -- Always remove first to avoid duplicate registration errors.
        self:unregisterHighlightButton()
        self:registerHighlightButton()
    else
        self:unregisterHighlightButton()
    end
end

-- ---------------------------------------------------------------------------
-- Main menu registration
-- ---------------------------------------------------------------------------

function Send2Notion:addToMainMenu(menu_items)
    menu_items.send2notion = {
        sorting_hint = "tools",
        text = _("Send note to Notion"),
        -- Single-tap opens the note dialog; long-press or sub-menu gives
        -- access to settings. KOReader's touchmenu shows a ▸ chevron when
        -- a sub_item_table is supplied, which also serves as a cue that
        -- there is more inside.
        callback = function() self:openNoteDialog(nil) end,
        hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Opens a quick note screen. The gear icon inside lets you switch target pages."),
                timeout = 4,
            })
        end,
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Write a new note…"),
                    callback = function() self:openNoteDialog(nil) end,
                },
                {
                    text = _("Settings"),
                    sub_item_table_func = function() return SettingsModule.buildMenu(self) end,
                    separator = true,
                },
            }
            return items
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Dispatcher action (optional gesture binding)
-- ---------------------------------------------------------------------------

function Send2Notion:onDispatcherRegisterActions()
    Dispatcher:registerAction("send2notion_note", {
        category = "none",
        event = "Send2NotionOpenNote",
        title = _("Send note to Notion"),
        general = true,
    })
end

function Send2Notion:onSend2NotionOpenNote()
    self:openNoteDialog(nil)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Send2Notion:init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.CONFIGURATION = CONFIGURATION

    self:onDispatcherRegisterActions()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Send2Notion:onReaderReady()
    self:refreshHighlightButton()
end

return Send2Notion
