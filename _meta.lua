local _ = require("gettext")

return {
    name = "send2notion",
    fullname = _("Send to Notion"),
    description = _([[Send quick notes and highlights from KOReader to a Notion page. Supports multiple targets (different integrations/pages) switchable from the note screen, optional highlight-menu button, and automatic retry once the device comes online.]]),
    version = "1.1.0",
}
