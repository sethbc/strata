-- lib/ui/voice_rows.lua
-- The VOICE page's rows (S.lib.ui_voice_rows): the voice's type row (3.8),
-- then every param of a voice in its sections: the built-in records'
-- (synth, grain, crossmod: lib/voices.lua's voice_rows), VOICE's own mix,
-- and the registered voice params' rows and sections (S.registry.voice_params'
-- voice_rows), as field_list rows, and the group of four rows the arc's rings edit. voice_page_rows and
-- voice_page_group are global; the rows are built from the voice's source
-- and type each call, so they follow a change at once. Not cached on purpose:
-- a call costs about 12 us (measured, docs/notes/lua/ui/field-list-and-cursors.md), and the
-- registered rows' when functions read more than the voice and its source.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The arc's rings edit this many rows at a time
  M.GROUP_SIZE = 4
  -- 3.8 (package 0d): the first row, the voice's type, in section "voice"
  -- with no label row above it (3b's preset row joins the section)
  M.VOICE_SECTION = "voice"
  M.TYPE_KIND = "type"
  -- 3.8 (package 3b): the second row, the voice's preset (no param: its
  -- key is the cursor's anchor; K3 opens S.lib.ui_voice_picker)
  M.PRESET_KIND = "preset"

  -- VOICE's own section, after the built-in records' (which name it as
  -- their before): the source, level and pan (Sub has no pan)
  local function mix_keys(voice_idx)
    local mix = {"source", "amp"}
    if S.lib.voices.is_synth_key(voice_idx, "pan") then table.insert(mix, "pan") end  -- Sub has none
    return mix
  end

  -- A record's rows for the voice: its rows (a list, or what its function
  -- gives) for which its when(voice_idx, key) holds (all of them without when)
  local function record_rows(voice_idx, voice_rows)
    local rows = voice_rows.rows
    if type(rows) == "function" then rows = rows(voice_idx) end
    local keys = {}
    for _, key in ipairs(rows) do
      if not voice_rows.when or voice_rows.when(voice_idx, key) then table.insert(keys, key) end
    end
    return keys
  end

  -- The sections, each {name, keys}: VOICE's mix section, then every
  -- record's rows (S.registry.voice_params' voice_rows, in registration
  -- order: the built-in synth, grain and crossmod records first, each
  -- before mix) at the end of its section; a section not there yet is
  -- added before the section named by before (if there is one), else at
  -- the end. A record's swaps then replace rows of its section. A section
  -- with no rows for this voice is left out (an input voice's synth section)
  local function sections_with_registered_rows(voice_idx)
    local sections = {{name = "mix", keys = mix_keys(voice_idx)}}
    local function section_named(name)
      for _, candidate in ipairs(sections) do
        if candidate.name == name then return candidate end
      end
    end
    for _, record in ipairs(S.registry.voice_params) do
      local voice_rows = record.voice_rows
      if voice_rows then
        local keys = record_rows(voice_idx, voice_rows)
        if #keys > 0 then
          local section = section_named(voice_rows.section)
          if not section then
            section = {name = voice_rows.section}
            local position = #sections + 1
            for index, candidate in ipairs(sections) do
              if candidate.name == voice_rows.before then position = index end
            end
            table.insert(sections, position, section)
          end
          -- a copy: a record's key lists are shared tables
          local section_rows = {}
          for _, key in ipairs(section.keys or {}) do table.insert(section_rows, key) end
          for _, key in ipairs(keys) do table.insert(section_rows, key) end
          section.keys = section_rows
        end
      end
    end
    for _, record in ipairs(S.registry.voice_params) do
      local voice_rows = record.voice_rows
      local section = voice_rows and voice_rows.swaps and section_named(voice_rows.section)
      if section then
        for index, key in ipairs(section.keys) do
          local swap = voice_rows.swaps[key]
          local swapped = swap and swap(voice_idx)
          if swapped then section.keys[index] = swapped end
        end
      end
    end
    return sections
  end

  -- A param's kind for the page and the arc: how its value moves
  local function param_kind(param_id, param)
    if param.t == params.tCONTROL then return "control" end
    if param.t == params.tOPTION then return "option" end
    if param.t == params.tNUMBER then return "number" end
    if param.t == params.tBINARY then return "binary" end
    error("VOICE row " .. param_id .. " has an unexpected param type " .. tostring(param.t))
  end

  local function check_voice(voice_idx)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then
      error("voice_page_rows: voice " .. tostring(voice_idx) .. " is not 1.." .. NUM_VOICES, 3)
    end
  end

  -- The rows of voice voice_idx: first the type row {label = "type",
  -- param_id = "v<i>_type", section = "voice", kind = "type", selectable =
  -- true} (3.8; no label row above it) and the preset row {label =
  -- "preset", kind = "preset", key = "preset", section = "voice",
  -- selectable = true} (3.8, package 3b: no param_id), then per section a label row
  -- {label = <section>, section = <section>, selectable = false}, then one
  -- row per param {label = <param name>, param_id, section, selectable =
  -- true, kind = "control"|"number"|"option"|"binary"}. The registered rows
  -- are included (sections_with_registered_rows)
  function voice_page_rows(voice_idx)
    check_voice(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local rows = {{label = "type", param_id = prefix .. "type", section = M.VOICE_SECTION, kind = M.TYPE_KIND,
      selectable = true},
      {label = "preset", kind = M.PRESET_KIND, key = "preset", section = M.VOICE_SECTION, selectable = true}}
    for _, section in ipairs(sections_with_registered_rows(voice_idx)) do
      if section.keys then
        table.insert(rows, {label = section.name, section = section.name, selectable = false})
        for _, key in ipairs(section.keys) do
          local param_id = prefix .. key
          local param = params:lookup_param(param_id)
          table.insert(rows, {label = param.name, param_id = param_id, section = section.name,
            selectable = true, kind = param_kind(param_id, param)})
        end
      end
    end
    return rows
  end

  -- The index of the first selectable row of voice_page_rows(voice_idx):
  -- the type row, 1, for every voice. It reads no voice, param or record,
  -- so S.cursors can start on it before init
  function M.first_field_row(voice_idx)
    check_voice(voice_idx)
    return 1
  end

  -- The cursor's group of GROUP_SIZE param rows (selectable rows with a
  -- param_id: the preset row, 3.8, is none, so no ring reaches it): with k
  -- the cursor's position among the param rows (the last at or before it,
  -- at least 1), group ceil(k / GROUP_SIZE), and the row indices of its
  -- param rows (fewer than GROUP_SIZE in the last group). The arc's rings
  -- 1-4 edit them in order.
  function voice_page_group(rows, cursor)
    local position = 0
    for index = 1, math.min(cursor, #rows) do
      if rows[index].selectable ~= false and rows[index].param_id then position = position + 1 end
    end
    local group = math.ceil(math.max(position, 1) / M.GROUP_SIZE)
    local first, last = M.GROUP_SIZE * group - (M.GROUP_SIZE - 1), M.GROUP_SIZE * group
    local row_indices, count = {}, 0
    for index, row in ipairs(rows) do
      if row.selectable ~= false and row.param_id then
        count = count + 1
        if count >= first and count <= last then table.insert(row_indices, index) end
      end
    end
    return group, row_indices
  end

  return M
end
