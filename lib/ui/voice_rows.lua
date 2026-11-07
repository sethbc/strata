-- lib/ui/voice_rows.lua
-- The VOICE page's rows (S.lib.ui_voice_rows): every param of a voice in
-- four sections (synth, grain, crossmod, mix), plus the registered voice
-- params' rows and sections (S.registry.voice_params' voice_rows), as
-- field_list rows, and the group of four rows the arc's rings edit. voice_page_rows and
-- voice_page_group are global; the rows are built from the voice's source
-- each call, so they follow a source change at once.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS

  -- A buffer-sourced voice's synth section (its synth is off)
  local BUFFER_SYNTH_KEYS = {"buf_pos", "buf_rate", "buf_scan"}
  local GRAIN_KEYS = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode"}
  -- The arc's rings edit this many rows at a time
  M.GROUP_SIZE = 4

  -- The param id suffixes of each section, in order; the synth section is
  -- nil for an input voice (none of its params do anything)
  local function section_keys(voice_idx)
    local voice = S.voices[voice_idx]
    local synth
    if voice_uses_synth(voice_idx) then
      synth = {}
      for _, key in ipairs(voice.param_order) do
        if key ~= "amp" and key ~= "pan" then table.insert(synth, key) end
      end
    elseif voice_uses_buffer(voice_idx) then
      synth = BUFFER_SYNTH_KEYS
    end
    local crossmod = {"mod_speed"}
    for slot = 1, NUM_MOD_SLOTS do
      table.insert(crossmod, "mod_source_" .. slot)
      table.insert(crossmod, "mod_amp_amt_" .. slot)
      table.insert(crossmod, "mod_freq_amt_" .. slot)
    end
    local mix = {"source", "amp"}
    if voice.params.pan ~= nil then table.insert(mix, "pan") end  -- Sub has none
    return {
      {name = "synth", keys = synth},
      {name = "grain", keys = GRAIN_KEYS},
      {name = "crossmod", keys = crossmod},
      {name = "mix", keys = mix},
    }
  end

  -- The sections with the registered rows (S.registry.voice_params'
  -- voice_rows, in registration order) added: each record's rows for which
  -- its when(voice_idx, key) holds (all of them without when) go at the end
  -- of its section; a section not there yet is added before the section
  -- named by before (if there is one), else at the end. A section with no
  -- rows for this voice is left out (an input voice's synth section)
  local function sections_with_registered_rows(voice_idx)
    local sections = section_keys(voice_idx)
    for _, record in ipairs(S.registry.voice_params) do
      local voice_rows = record.voice_rows
      if voice_rows then
        local keys = {}
        for _, key in ipairs(voice_rows.rows) do
          if not voice_rows.when or voice_rows.when(voice_idx, key) then table.insert(keys, key) end
        end
        if #keys > 0 then
          local section
          for _, candidate in ipairs(sections) do
            if candidate.name == voice_rows.section then section = candidate end
          end
          if not section then
            section = {name = voice_rows.section}
            local position = #sections + 1
            for index, candidate in ipairs(sections) do
              if candidate.name == voice_rows.before then position = index end
            end
            table.insert(sections, position, section)
          end
          -- a copy: the built-in key lists are shared tables
          local section_rows = {}
          for _, key in ipairs(section.keys or {}) do table.insert(section_rows, key) end
          for _, key in ipairs(keys) do table.insert(section_rows, key) end
          section.keys = section_rows
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

  -- The rows of voice voice_idx: per section a label row
  -- {label = <section>, section = <section>, selectable = false}, then one
  -- row per param {label = <param name>, param_id, section, selectable =
  -- true, kind = "control"|"number"|"option"|"binary"}. The registered rows
  -- are included (sections_with_registered_rows)
  function voice_page_rows(voice_idx)
    check_voice(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local rows = {}
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

  -- The index of the first selectable row of voice_page_rows(voice_idx),
  -- from the built-in sections alone: it needs no params or registered
  -- records, so S.cursors can start on it before init. (A registered row
  -- never changes it: the first section's first field is row 2 either way)
  function M.first_field_row(voice_idx)
    check_voice(voice_idx)
    local index = 0
    for _, section in ipairs(section_keys(voice_idx)) do
      if section.keys then
        if #section.keys > 0 then return index + 2 end  -- after the section's label row
        index = index + 1
      end
    end
    return 1
  end

  -- The cursor's group of GROUP_SIZE selectable rows: with k the cursor's
  -- position among the selectable rows, group ceil(k / GROUP_SIZE), and the
  -- row indices of its selectable rows (fewer than GROUP_SIZE in the last
  -- group). The arc's rings 1-4 edit them in order.
  function voice_page_group(rows, cursor)
    local position = S.lib.ui_field_list.ordinal(rows, cursor)
    local group = math.ceil(position / M.GROUP_SIZE)
    local first, last = M.GROUP_SIZE * group - (M.GROUP_SIZE - 1), M.GROUP_SIZE * group
    local row_indices, count = {}, 0
    for index, row in ipairs(rows) do
      if row.selectable ~= false then
        count = count + 1
        if count >= first and count <= last then table.insert(row_indices, index) end
      end
    end
    return group, row_indices
  end

  return M
end
