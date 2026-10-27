-- Pandoc filter: Markdown guide conventions -> abnTeX2 floats and inline code.
-- Caption paragraphs ("**Figura N – título**") precede the figure or table;
-- "Fonte:" and "Nota:" paragraphs follow it (ABNT NBR 14724 / IBGE).

local stringify = pandoc.utils.stringify

local function latex_inlines(inlines)
  local doc = pandoc.Pandoc({ pandoc.Plain(inlines) })
  return (pandoc.write(doc, "latex"):gsub("%s+$", ""))
end

local function latex_blocks(blocks)
  return (pandoc.write(pandoc.Pandoc(blocks), "latex"):gsub("%s+$", ""))
end

local SPECIAL = {
  ["\\"] = "\\textbackslash{}", ["{"] = "\\{", ["}"] = "\\}", ["$"] = "\\$",
  ["&"] = "\\&", ["#"] = "\\#", ["%"] = "\\%", ["_"] = "\\_",
  ["^"] = "\\textasciicircum{}", ["~"] = "\\textasciitilde{}",
  ["<"] = "\\textless{}", [">"] = "\\textgreater{}", ["|"] = "\\textbar{}",
  ["-"] = "-{}", ["'"] = "\\textquotesingle{}", ["`"] = "\\textasciigrave{}",
}
local BREAK_AFTER = { ["/"] = true, ["."] = true, [":"] = true, ["_"] = true,
  ["-"] = true, ["="] = true, [","] = true, ["|"] = true, ["("] = true }

function Code(el)
  local out, previous = {}, ""
  for _, cp in utf8.codes(el.text) do
    local ch = utf8.char(cp)
    if ch:match("^%u$") and previous:match("^%l$") then out[#out + 1] = "\\allowbreak{}" end
    out[#out + 1] = SPECIAL[ch] or ch
    if BREAK_AFTER[ch] then out[#out + 1] = "\\allowbreak{}" end
    previous = ch
  end
  return pandoc.RawInline("latex", "\\texttt{" .. table.concat(out) .. "}")
end

function Link(el)
  if el.target:match("^https?://") then return nil end
  return el.content
end

function BlockQuote(el)
  return pandoc.RawBlock("latex",
    "\\begin{mdframed}[linewidth=0.6pt,innertopmargin=6pt,innerbottommargin=6pt]\n"
    .. "\\small\n" .. latex_blocks(el.content) .. "\n\\end{mdframed}")
end

local function caption_of(block)
  if block.t ~= "Para" or #block.content ~= 1 or block.content[1].t ~= "Strong" then
    return nil
  end
  local text = stringify(block.content[1])
  local kind, number = text:match("^(%a+) (%d+) – ")
  if kind ~= "Figura" and kind ~= "Quadro" and kind ~= "Tabela" then return nil end
  local inlines, rest = block.content[1].content, pandoc.List()
  for i = 7, #inlines do rest:insert(inlines[i]) end
  return kind, tonumber(number), rest
end

local function note_of(block, label)
  if block == nil or block.t ~= "Para" then return nil end
  local first = block.content[1]
  if first == nil or first.t ~= "Str" or first.text ~= label .. ":" then return nil end
  local rest = pandoc.List(block.content)
  rest:remove(1)
  if rest[1] and rest[1].t == "Space" then rest:remove(1) end
  return latex_inlines(rest)
end

local function image_of(block)
  if block.t == "Figure" then
    local img = nil
    block:walk({ Image = function(i) img = i end })
    return img
  end
  if block.t == "Para" and #block.content == 1 and block.content[1].t == "Image" then
    return block.content[1]
  end
  return nil
end

local function column_spec(tbl, ruled)
  local weights, total = {}, 0
  local rows = pandoc.List()
  for _, row in ipairs(tbl.head.rows) do rows:insert(row) end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do rows:insert(row) end
  end
  local ncols = #tbl.colspecs
  for c = 1, ncols do weights[c] = 4 end
  for _, row in ipairs(rows) do
    for c, cell in ipairs(row.cells) do
      local len = utf8.len(stringify(cell.contents)) or 0
      if len > weights[c] then weights[c] = len end
    end
  end
  for c = 1, ncols do
    weights[c] = math.sqrt(weights[c])
    total = total + weights[c]
  end
  local parts = {}
  for c = 1, ncols do
    local share = weights[c] * ncols / total
    parts[#parts + 1] = string.format(
      ">{\\raggedright\\arraybackslash\\hsize=%.3f\\hsize}X", share)
  end
  local sep = ruled and "|" or ""
  return sep .. table.concat(parts, sep) .. sep, rows, #tbl.head.rows
end

local function table_latex(tbl, kind, title, source, note)
  local quadro = kind == "Quadro"
  local spec, rows, nhead = column_spec(tbl, quadro)
  local lines = {}
  local env = quadro and "quadro" or "table"
  lines[#lines + 1] = "\\begin{" .. env .. "}[htbp]"
  lines[#lines + 1] = "\\caption{" .. title .. "}"
  lines[#lines + 1] = "\\footnotesize"
  lines[#lines + 1] = "\\begin{tabularx}{\\textwidth}{" .. spec .. "}"
  lines[#lines + 1] = quadro and "\\hline" or "\\toprule"
  for r, row in ipairs(rows) do
    local cells = {}
    for _, cell in ipairs(row.cells) do
      local content = latex_blocks(cell.contents)
      if r <= nhead then content = "\\textbf{" .. content .. "}" end
      cells[#cells + 1] = content
    end
    lines[#lines + 1] = table.concat(cells, " & ") .. " \\\\"
    if r == nhead then
      lines[#lines + 1] = quadro and "\\hline" or "\\midrule"
    elseif quadro then
      lines[#lines + 1] = "\\hline"
    end
  end
  if not quadro then lines[#lines + 1] = "\\bottomrule" end
  lines[#lines + 1] = "\\end{tabularx}"
  lines[#lines + 1] = "\\fonte{" .. source .. "}"
  if note then lines[#lines + 1] = "\\nota{" .. note .. "}" end
  lines[#lines + 1] = "\\end{" .. env .. "}"
  return table.concat(lines, "\n")
end

local function figure_latex(img, title, source, note)
  local lines = {
    "\\begin{figure}[htbp]",
    "\\caption{" .. title .. "}",
    "\\includegraphics[width=\\textwidth,height=0.72\\textheight,keepaspectratio]{" .. img.src .. "}",
    "\\fonte{" .. source .. "}",
  }
  if note then lines[#lines + 1] = "\\nota{" .. note .. "}" end
  lines[#lines + 1] = "\\end{figure}"
  return table.concat(lines, "\n")
end

local counters = { Figura = 0, Quadro = 0, Tabela = 0 }

function Pandoc(doc)
  local out = pandoc.List()
  local blocks = doc.blocks
  local i = 1
  while i <= #blocks do
    local kind, number, title_inlines = caption_of(blocks[i])
    if kind then
      counters[kind] = counters[kind] + 1
      assert(counters[kind] == number,
        string.format("%s %d fora de sequência (esperado %d)", kind, number, counters[kind]))
      local target = blocks[i + 1]
      local source = note_of(blocks[i + 2], "Fonte")
      assert(source, string.format("%s %d sem linha 'Fonte:'", kind, number))
      local note = note_of(blocks[i + 3], "Nota")
      local title = latex_inlines(title_inlines)
      if kind == "Figura" then
        local img = image_of(target)
        assert(img, string.format("Figura %d sem imagem", number))
        out:insert(pandoc.RawBlock("latex", figure_latex(img, title, source, note)))
      else
        assert(target.t == "Table", string.format("%s %d sem tabela", kind, number))
        out:insert(pandoc.RawBlock("latex", table_latex(target, kind, title, source, note)))
      end
      i = i + (note and 4 or 3)
    else
      out:insert(blocks[i])
      i = i + 1
    end
  end
  doc.blocks = out
  return doc
end

return {
  { Code = Code, Link = Link },
  { BlockQuote = BlockQuote },
  { Pandoc = Pandoc },
}
