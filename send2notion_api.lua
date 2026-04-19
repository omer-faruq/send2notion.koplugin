-- send2notion_api.lua
--
-- Minimal Notion REST API client. Only the handful of endpoints needed by
-- the plugin are exposed:
--   * whoAmI       : GET  /v1/users/me        (token sanity check)
--   * getPage      : GET  /v1/pages/{id}      (page access check)
--   * appendBlocks : PATCH /v1/blocks/{id}/children
--   * createSubpage: POST /v1/pages           (child page under a parent)
--
-- All requests go through HTTPS; the Notion API has no HTTP fallback.
-- Rich text items are capped at ~2000 chars by Notion; the helpers in
-- this module take care of UTF-8 safe chunking so long book excerpts are
-- never silently truncated.
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local Api = {}

local USER_AGENT = "KOReader send2notion/1.0"
local API_HOST = "https://api.notion.com"
local API_VERSION = "2022-06-28"

-- Notion caps each rich_text item at 2000 chars. We keep a small safety
-- margin so we never hit the edge because of multi-byte UTF-8 boundaries.
local MAX_RICH_TEXT_CHARS = 1900
-- Notion caps a single "children" request at 100 blocks.
local MAX_CHILDREN_PER_REQUEST = 100

-- ---------------------------------------------------------------------------
-- Low-level request plumbing
-- ---------------------------------------------------------------------------

local function requestWithScheme(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "https"
    if scheme == "https" then
        https.cert_verify = false
        return https.request(options)
    end
    return http.request(options)
end

local function safeJsonDecode(payload)
    if not payload or payload == "" then return nil end
    local ok, decoded = pcall(function() return json.decode(payload) end)
    if ok then return decoded end
    return nil
end

local function buildHeaders(token, content_length)
    return {
        ["Authorization"] = "Bearer " .. tostring(token or ""),
        ["Notion-Version"] = API_VERSION,
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(content_length or 0),
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json",
    }
end

-- Perform an HTTP request to the Notion API. Returns ok(bool), decoded
-- body(table|nil), err(string|nil). The body is always JSON for Notion,
-- even on error (the service returns {object:"error", code:..., message:...}).
local function doRequest(token, method, path, body_table)
    if not token or token == "" then
        return false, nil, "Missing Notion integration token"
    end
    local target_url = API_HOST .. path
    local body = ""
    if body_table ~= nil then
        local ok_enc, encoded = pcall(json.encode, body_table)
        if not ok_enc then
            return false, nil, "Failed to encode request body"
        end
        body = encoded
    end

    local sink = {}

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    -- http.request with a sink returns (1, code, headers, status) on
    -- success and (nil, err) on transport failure. We therefore keep
    -- four return values and avoid socket.skip() which would shift them.
    local request_opts = {
        url = target_url,
        method = method,
        headers = buildHeaders(token, #body),
        sink = ltn12.sink.table(sink),
    }
    if body ~= "" then
        request_opts.source = ltn12.source.string(body)
    end
    local _, code, _, status = requestWithScheme(request_opts)
    socketutil:reset_timeout()

    local response_body = table.concat(sink or {})
    local decoded = safeJsonDecode(response_body)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        return false, nil, "Request timed out"
    end

    local numeric_code = tonumber(code)

    -- Treat any 2xx as success.
    if numeric_code and numeric_code >= 200 and numeric_code < 300 then
        return true, decoded, nil
    end

    -- Prefer Notion's structured error message when present.
    if decoded and decoded.message then
        local err_code = decoded.code or tostring(numeric_code or "?")
        return false, decoded, string.format("Notion API error (%s): %s",
            tostring(err_code), tostring(decoded.message))
    end

    if not numeric_code then
        logger.warn("send2notion: network error:", status or code)
        return false, nil, "Network error: " .. tostring(status or code)
    end

    return false, decoded, string.format("HTTP %s: %s", tostring(numeric_code), status or "")
end

-- ---------------------------------------------------------------------------
-- Helpers exposed to the note-dialog for message assembly
-- ---------------------------------------------------------------------------

-- Normalise a Notion page id to the 32-char hex form without dashes that
-- the API accepts. Accepts both the raw hex and the dashed UUID form a
-- user may paste from a Notion URL.
function Api.normalizePageId(page_id)
    if type(page_id) ~= "string" then return nil end
    local cleaned = page_id:gsub("-", ""):gsub("%s+", ""):lower()
    if cleaned:match("^[0-9a-f]+$") and #cleaned == 32 then
        return cleaned
    end
    return nil
end

-- Split `text` into chunks of at most MAX_RICH_TEXT_CHARS *bytes*, backing
-- off at UTF-8 continuation bytes so we never cut a multi-byte codepoint
-- in half. Returns an array of strings; empty input yields an empty array.
local function utf8SafeChunks(text, max_bytes)
    local chunks = {}
    if type(text) ~= "string" or text == "" then return chunks end
    max_bytes = max_bytes or MAX_RICH_TEXT_CHARS
    local n = #text
    local i = 1
    while i <= n do
        local end_pos = math.min(i + max_bytes - 1, n)
        if end_pos < n then
            -- Back off while the next byte is a UTF-8 continuation byte
            -- (binary 10xxxxxx, i.e. 0x80..0xBF).
            while end_pos > i do
                local b = text:byte(end_pos + 1)
                if not b or b < 0x80 or b >= 0xC0 then break end
                end_pos = end_pos - 1
            end
        end
        table.insert(chunks, text:sub(i, end_pos))
        i = end_pos + 1
    end
    return chunks
end

-- Build a rich_text array for a single logical piece of text. Line
-- breaks are preserved verbatim; oversized strings are split across
-- multiple rich_text items so the final block renders as one paragraph.
local function richText(text, annotations)
    local items = {}
    for _, chunk in ipairs(utf8SafeChunks(text, MAX_RICH_TEXT_CHARS)) do
        local item = {
            type = "text",
            text = { content = chunk },
        }
        if annotations then item.annotations = annotations end
        table.insert(items, item)
    end
    return items
end

function Api.paragraphBlock(text, annotations)
    return {
        object = "block",
        type = "paragraph",
        paragraph = {
            rich_text = richText(text or "", annotations),
        },
    }
end

function Api.quoteBlock(text)
    return {
        object = "block",
        type = "quote",
        quote = {
            rich_text = richText(text or ""),
        },
    }
end

function Api.headingBlock(text, level)
    level = level or 3
    local type_name
    if level <= 1 then type_name = "heading_1"
    elseif level == 2 then type_name = "heading_2"
    else type_name = "heading_3" end
    local block = {
        object = "block",
        type = type_name,
    }
    block[type_name] = {
        rich_text = richText(text or ""),
    }
    return block
end

function Api.dividerBlock()
    return {
        object = "block",
        type = "divider",
        divider = {},
    }
end

-- ---------------------------------------------------------------------------
-- API endpoints
-- ---------------------------------------------------------------------------

--- Verify that an integration token is reachable. Returns ok, user_name_or_err.
function Api.whoAmI(token)
    local ok, decoded, err = doRequest(token, "GET", "/v1/users/me", nil)
    if not ok then return false, err end
    local name = decoded and (decoded.name or (decoded.bot and decoded.bot.owner and "integration") or "bot")
    return true, name or "bot"
end

--- Verify that the integration has access to a specific page.
-- Returns ok, err.
function Api.getPage(token, page_id)
    local pid = Api.normalizePageId(page_id)
    if not pid then return false, "Invalid Notion page id (expected 32 hex chars)" end
    local ok, _decoded, err = doRequest(token, "GET", "/v1/pages/" .. pid, nil)
    return ok, err
end

--- Append an array of block objects to a page. Splits into batches of
-- MAX_CHILDREN_PER_REQUEST so arbitrarily long notes keep working.
-- `target_id` is either a page id or a block id (Notion treats them the
-- same for the children endpoint). Returns ok, err.
function Api.appendBlocks(token, target_id, blocks)
    local pid = Api.normalizePageId(target_id)
    if not pid then return false, "Invalid Notion page id (expected 32 hex chars)" end
    if type(blocks) ~= "table" or #blocks == 0 then
        return false, "No blocks to append"
    end
    local i = 1
    while i <= #blocks do
        local batch = {}
        for j = i, math.min(i + MAX_CHILDREN_PER_REQUEST - 1, #blocks) do
            table.insert(batch, blocks[j])
        end
        local ok, _decoded, err = doRequest(token, "PATCH",
            "/v1/blocks/" .. pid .. "/children",
            { children = batch })
        if not ok then return false, err end
        i = i + MAX_CHILDREN_PER_REQUEST
    end
    return true, nil
end

--- Create a new sub-page under `parent_page_id` with the given title
-- and initial blocks as children. Returns ok, new_page_id_or_err.
function Api.createSubpage(token, parent_page_id, title, children)
    local pid = Api.normalizePageId(parent_page_id)
    if not pid then return false, "Invalid Notion page id (expected 32 hex chars)" end
    local body = {
        parent = { type = "page_id", page_id = pid },
        properties = {
            title = {
                title = richText(title or "Note"),
            },
        },
    }
    if type(children) == "table" and #children > 0 then
        -- Notion caps the initial creation to 100 children; we pass at
        -- most that many here and use appendBlocks for any overflow.
        local head = {}
        for i = 1, math.min(#children, MAX_CHILDREN_PER_REQUEST) do
            table.insert(head, children[i])
        end
        body.children = head
    end
    local ok, decoded, err = doRequest(token, "POST", "/v1/pages", body)
    if not ok then return false, err end
    local new_id = decoded and decoded.id
    -- Push any remaining blocks past the first 100 into the new page.
    if type(children) == "table" and #children > MAX_CHILDREN_PER_REQUEST and new_id then
        local rest = {}
        for i = MAX_CHILDREN_PER_REQUEST + 1, #children do
            table.insert(rest, children[i])
        end
        local ok_rest, err_rest = Api.appendBlocks(token, new_id, rest)
        if not ok_rest then return false, err_rest end
    end
    return true, new_id
end

return Api
