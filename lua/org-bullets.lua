local M = {}

local fn = vim.fn
local api = vim.api

local org_ns = api.nvim_create_namespace("org_bullets")
local org_headline_hl = "OrgHeadlineLevel"

local symbols = { "◉", "○", "✸", "✿" }
local bullet_chars = "-+*"
local list_groups = {
  ["-"] = "OrgHeadlineLevel1",
  ["+"] = "OrgHeadlineLevel2",
  ["*"] = "OrgHeadlineLevel3",
}

---@class BulletsConfig
---@field public show_current_line boolean
---@field public symbols string[] | function(symbols: string[]): string[]
---@field public indent boolean
local config = {
  show_current_line = false,
  symbols = symbols,
  indent = true,
  bullet_chars = bullet_chars,
  bullet_symbol = "•",
}

---@type table<integer,integer>
local marks = {}

---Sets of pairs {pattern = handler}
---handler
---@param str string
---@param conf BulletsConfig
---@return string symbol, string highlight_group
local markers = {}

---@type table
local last_lnum = { mark = nil, lnum = nil }

---Merge a user config with the defaults
---@param conf BulletsConfig
local function set_config(conf)
  if conf.symbols and type(conf.symbols) == "function" then
    conf.symbols = conf.symbols(symbols) or symbols
  end

  if conf.bullet_chars and type(conf.bullet_chars) == "function" then
    conf.bullet_chars = conf.bullet_chars(bullet_chars) or bullet_chars
  end

  config = vim.tbl_extend("keep", conf, config)
end

---Set an extmark (safely)
---@param virt_text string[] a tuple of character and highlight
---@param lnum integer
---@param start_col integer
---@param end_col integer
---@param highlight string
local function set_mark(virt_text, lnum, start_col, end_col, highlight)
  local ok, result = pcall(api.nvim_buf_set_extmark, 0, org_ns, lnum, start_col, {
    end_col = end_col,
    hl_group = highlight,
    virt_text = { virt_text },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
  if not ok then
    api.nvim_echo({ { result, "ErrorMsg" } }, true, {})
  else
    marks[lnum] = result
  end
end

---Add padding to the given symbol
---@param symbol string
---@param padding_spaces number
---@param padding_in_front boolean
local function add_symbol_padding(symbol, padding_spaces, padding_in_front)
  if padding_in_front then
    return string.rep(" ", padding_spaces - 1) .. symbol
  else
    return symbol .. string.rep(" ", padding_spaces)
  end
end

---Set the a single line extmark
---@param lnum number
---@param line number
---@param conf BulletsConfig
local function set_line_mark(lnum, line, conf)
  for pattern, handler in pairs(markers) do
    local match = fn.matchstrpos(line, pattern)
    local str, start_col, end_col = match[1], match[2], match[3]
    if start_col > -1 and end_col > -1 then
      set_mark(handler(str, conf), lnum, start_col, end_col)
    end
  end
end

---Apply the the bullet markers to the whole buffer
---used on reloading the buffer or on first entering
local function conceal_buffer()
  marks = {}
  api.nvim_buf_clear_namespace(0, org_ns, 0, -1)
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  for index, line in ipairs(lines) do
    set_line_mark(index - 1, line, config)
  end
end

---Update only a range of changed lines based on a buffer update
---@see: :help api-buffer-updates-lua
---@param _ 'lines' 'the event type'
---@param buf integer 'the buffer number'
---@param __ integer 'the changed tick'
---@param firstline number 'the first line in the changed range'
---@param lastline number 'the previous last line'
---@param new_lastline number 'the updated last line'
---@param byte_count integer
local function update_changed_lines(_, buf, __, firstline, lastline, new_lastline, byte_count)
  if firstline == lastline and lastline == new_lastline and byte_count == 0 then
    -- on_lines can be called twice for undo events; ignore the second
    -- call which indicates no changes.
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, true)
  local index = 1
  for lnum = firstline, new_lastline - 1 do
    local id = marks[lnum]
    if id then
      api.nvim_buf_del_extmark(0, org_ns, id)
    end
    set_line_mark(lnum, lines[index], config)
    index = index + 1
  end
end

---Re-add the lnum that was revealed on the last cursor move
---@param lnum number
local function apply_previous_extmark(lnum)
  local mark = last_lnum.mark and last_lnum.mark[3] or nil
  if not mark then
    return
  end
  local start_col = last_lnum.mark[2]
  local end_col = mark.end_col
  set_mark(mark.virt_text[1], last_lnum.lnum, start_col, end_col, mark.hl_group)
end

local function toggle_line_visibility()
  local pos = api.nvim_win_get_cursor(0)
  local lnum = pos[1] - 1
  local changed = last_lnum and last_lnum.lnum ~= lnum
  if changed then
    apply_previous_extmark(lnum)
  end
  -- order matters here, this should happen AFTER re-adding previous marks
  -- also update the line number no matter what
  local id = marks[lnum]
  if not id then
    return
  end
  local mark = api.nvim_buf_get_extmark_by_id(0, org_ns, id, { details = true })
  api.nvim_buf_del_extmark(0, org_ns, id)
  marks[lnum] = nil
  if changed then
    last_lnum = {
      lnum = lnum,
      mark = mark,
    }
  end
end

--- Initialise autocommands for the org buffer
--- @param conf BulletsConfig
local function setup_autocommands(conf)
  local utils = require("org-bullets.utils")
  local commands = {
    {
      events = { "BufRead", "TextChanged", "TextChangedI", "TextChangedP" },
      targets = { "<buffer>" },
      command = utils.throttle(50, conceal_buffer),
    },
  }
  if conf and conf.show_current_line then
    table.insert(commands, {
      events = { "CursorMoved" },
      targets = { "<buffer>" },
      command = toggle_line_visibility,
    })
  end
  utils.augroup("OrgBullets", commands)
end

--- Setup markers used for matching various "bullet symbols" on lines
local function setup_markers()
  markers = {
    -- Headers
    ["^\\*\\{1,}\\ze\\s"] = function(str, conf)
      local level = #str
      local symbol = add_symbol_padding(
        (conf.symbols[level] or conf.symbols[1]),
        (level <= 0 and 0 or level),
        conf.indent
      )
      local highlight = org_headline_hl .. level
      return { symbol, highlight }
    end,
    -- List checkboxes '- [x]'
    ["^\\s*\\-\\s\\[\\zsx\\ze\\]"] = function(_)
      return { "✓", "OrgDone" }
    end,
    -- List partial checkboxes '- [-]'
    ["^\\s*\\-\\s\\[\\zs\\-\\ze\\]"] = function(_)
      return { "~", "OrgDone" }
    end,
    -- Numbered checkboxes '1. [x]'
    ["^\\s*\\d\\+\\.\\s\\[\\zsx\\ze\\]"] = function(_)
      return { "✓", "OrgDone" }
    end,
    -- Numbered partial checkboxes '1. [-]'
    ["^\\s*\\d\\+\\.\\s\\[\\zs-\\ze\\]"] = function(_)
      return { "~", "OrgDone" }
    end,
    -- List bullets *,+,- (or as configured by the user)
    ["^\\s*[" .. config.bullet_chars .. "]\\s"] = function(str)
      local symbol = add_symbol_padding(config.bullet_symbol, (#str - 1), true)
      return { symbol, list_groups[vim.trim(str)] }
    end,
  }
end

--- Apply plugin to the current org buffer. This is called from a ftplugin
--- so it applies to any org buffers opened
function M.__init()
  conceal_buffer()
  setup_autocommands(config)
end

---Save the user config and initialise the plugin
---@param conf BulletsConfig
function M.setup(conf)
  set_config(conf or {})
  setup_markers()
end

return M
