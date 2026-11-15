#!/usr/bin/env python3
"""Write Strata's two TouchOSC layouts from tools/touchosc/layout.lua.

Run on demand from the repository root (never by the tests):

    python3 tools/touchosc/generate.py

It needs Python 3 (standard library only) and a `lua` or `luajit` on the PATH,
which reads layout.lua and hands its table over as JSON. It writes
extras/touchosc/strata-tablet.tosc and strata-phone.tosc and prints, for each,
the decompressed size and the count of controls.

The file format is the one the tosclib library writes (a zlib-compressed XML
document, <lexml version="3">, one root GROUP holding a PAGER of GROUP pages),
as docs/design/3.6-facts/checks.md section 5 describes it. Hexler publishes no
schema and no file written here has been opened in TouchOSC.
"""

import json
import shutil
import subprocess
import sys
import uuid
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent.parent
LAYOUT = ROOT / "tools" / "touchosc" / "layout.lua"
OUT_DIR = ROOT / "extras" / "touchosc"

# Lua prints the layout table as JSON (a table with 1..n keys is a list)
LUA_TO_JSON = r"""
local function encode(v)
  local t = type(v)
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local out = {}
      for i, item in ipairs(v) do out[i] = encode(item) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = string.format("%q:%s", k, encode(v[k])) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif t == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end
io.write(encode(dofile(arg[1])))
"""

COLORS = {
    "background": (0.08, 0.09, 0.10, 1.0),
    "fader": (0.20, 0.60, 0.55, 1.0),
    "toggle": (0.85, 0.55, 0.15, 1.0),
    "button": (0.35, 0.40, 0.75, 1.0),
    "label": (1.0, 1.0, 1.0, 1.0),
}


def read_layout():
    lua = shutil.which("lua") or shutil.which("luajit")
    if lua is None:
        sys.exit("generate.py: no lua or luajit on the PATH")
    result = subprocess.run([lua, "-e", LUA_TO_JSON.replace("arg[1]", json.dumps(str(LAYOUT))), ],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def number(value):
    return repr(float(value))


def prop(parent, kind, key, value):
    node = ET.SubElement(parent, "property", {"type": kind})
    ET.SubElement(node, "key").text = key
    holder = ET.SubElement(node, "value")
    if kind == "r":
        for name, part in zip(("x", "y", "w", "h"), value):
            ET.SubElement(holder, name).text = number(part)
    elif kind == "c":
        for name, part in zip(("r", "g", "b", "a"), value):
            ET.SubElement(holder, name).text = number(part)
    elif kind == "b":
        holder.text = "1" if value else "0"
    else:
        holder.text = str(value)
    return node


def value(parent, key, default=0):
    node = ET.SubElement(parent, "value")
    ET.SubElement(node, "key").text = key
    ET.SubElement(node, "locked").text = "0"
    ET.SubElement(node, "lockedDefaultCurrent").text = "0"
    ET.SubElement(node, "default").text = str(default)
    ET.SubElement(node, "defaultPull").text = "0"
    return node


def partial(parent, kind, conversion, text, low=0, high=1):
    node = ET.SubElement(parent, "partial")
    ET.SubElement(node, "type").text = kind
    ET.SubElement(node, "conversion").text = conversion
    ET.SubElement(node, "value").text = str(text)
    ET.SubElement(node, "scaleMin").text = str(low)
    ET.SubElement(node, "scaleMax").text = str(high)


def osc_message(messages, path, argument, send, receive, trigger="ANY"):
    """argument: ("VALUE", conversion, low, high) or ("CONSTANT", conversion, constant)."""
    osc = ET.SubElement(messages, "osc")
    ET.SubElement(osc, "enabled").text = "1"
    ET.SubElement(osc, "send").text = "1" if send else "0"
    ET.SubElement(osc, "receive").text = "1" if receive else "0"
    ET.SubElement(osc, "feedback").text = "0"
    ET.SubElement(osc, "connections").text = "00001"
    triggers = ET.SubElement(osc, "triggers")
    trig = ET.SubElement(triggers, "trigger")
    ET.SubElement(trig, "var").text = "x"
    ET.SubElement(trig, "condition").text = trigger
    partial(ET.SubElement(osc, "path"), "CONSTANT", "STRING", path)
    arguments = ET.SubElement(osc, "arguments")
    if argument[0] == "VALUE":
        partial(arguments, "VALUE", argument[1], "x", argument[2], argument[3])
    else:
        partial(arguments, "CONSTANT", argument[1], argument[2])


# A fixed namespace: a node's ID is the uuid5 of its path in the layout, so a run changes nothing
NAMESPACE = uuid.UUID("5d0c7e1e-3a54-4c53-9a3b-7b1f6f0f2a10")


def node_id(path):
    return str(uuid.uuid5(NAMESPACE, path))


def node(parent, kind, name, frame, color, path, interactive=True):
    element = ET.SubElement(parent, "node", {"ID": node_id(path), "type": kind})
    props = ET.SubElement(element, "properties")
    prop(props, "s", "name", name)
    prop(props, "r", "frame", frame)
    prop(props, "c", "color", color)
    prop(props, "b", "locked", False)
    prop(props, "b", "visible", True)
    prop(props, "b", "interactive", interactive)
    prop(props, "b", "background", True)
    prop(props, "b", "outline", True)
    values = ET.SubElement(element, "values")
    messages = ET.SubElement(element, "messages")
    return element, props, values, messages


def label(parent, text, frame, path):
    element, props, values, _ = node(parent, "LABEL", "label " + text, frame, COLORS["label"], path + "/label", interactive=False)
    props.find("property[key='background']/value").text = "0"
    props.find("property[key='outline']/value").text = "0"
    prop(props, "i", "textSize", 14)
    prop(props, "i", "textAlignH", 2)
    prop(props, "s", "font", "0")
    holder = value(values, "text", text)
    value(values, "touch", "false")
    return holder


def control(parent, spec, cell_w, cell_h, count, path):
    frame = (spec["x"] * cell_w, spec["y"] * cell_h, spec["w"] * cell_w, spec["h"] * cell_h)
    kind = spec["kind"]
    tosc_type = "FADER" if kind == "fader" else "BUTTON"
    element, props, values, messages = node(parent, tosc_type, spec["label"], frame, COLORS[kind], path)
    if tosc_type == "FADER":
        prop(props, "i", "response", 0)
        prop(props, "b", "bar", True)
        prop(props, "b", "cursor", True)
        prop(props, "i", "orientation", 0)
    else:
        # a toggle changes on press; a scene button is momentary
        prop(props, "i", "buttonType", 0 if kind == "button" else 2)
    value(values, "touch", "false")
    value(values, "x", 0)
    if "param" in spec:
        low, high = spec["min"], spec["max"]
        osc_message(messages, "/param/" + spec["param"], ("VALUE", "FLOAT", low, high), True, True)
    elif kind == "button":
        osc_message(messages, spec["address"], ("CONSTANT", "INTEGER", spec["argument"]), True, False, "RISE")
    else:
        # a toggle sends its 0 or 1 and listens for Strata's feedback of the same state
        osc_message(messages, spec["address"], ("VALUE", "INTEGER", 0, 1), True, False)
        listen = spec["address"].replace("/run", "/running") if "/run" in spec["address"] else spec["address"]
        if listen != spec["address"]:
            osc_message(messages, listen, ("VALUE", "INTEGER", 0, 1), False, True)
        else:
            messages.findall("osc")[0].find("receive").text = "1"
    label(parent, spec["label"], (frame[0], frame[1], frame[2], min(frame[3], 24.0)), path)
    count[0] += 2


def build(layout):
    width, height = layout["width"], layout["height"]
    name = layout["name"]
    root = ET.Element("lexml", {"version": "3"})
    top, props, values, messages = node(root, "GROUP", name, (0.0, 0.0, width, height), COLORS["background"], name)
    children = ET.SubElement(top, "children")
    pager, pager_props, _, _ = node(children, "PAGER", "pages", (0.0, 0.0, width, height), COLORS["background"],
                                    name + "/pages")
    prop(pager_props, "b", "tabbar", True)
    prop(pager_props, "i", "tabbarSize", 40)
    page_children = ET.SubElement(pager, "children")
    count = [2]
    for page in layout["pages"]:
        page_path = name + "/" + page["title"]
        group, group_props, _, _ = node(page_children, "GROUP", page["title"], (0.0, 0.0, width, height),
                                         COLORS["background"], page_path)
        prop(group_props, "s", "tabLabel", page["title"])
        inner = ET.SubElement(group, "children")
        count[0] += 1
        usable_h = height - 40.0
        cell_w, cell_h = width / page["columns"], usable_h / page["rows"]
        for spec in page["controls"]:
            control(inner, spec, cell_w, cell_h, count, page_path + "/" + spec["label"])
    return root, count[0]


def render(layout):
    """The file's bytes and its node count: the same bytes every run (ids are uuid5 of a node's path)."""
    root, nodes = build(layout)
    raw = ET.tostring(root, encoding="UTF-8")
    return zlib.compress(raw, 9), len(raw), nodes


def main():
    check = "--check" in sys.argv[1:]
    unknown = [argument for argument in sys.argv[1:] if argument != "--check"]
    if unknown:
        sys.exit("usage: generate.py [--check]")
    data = read_layout()
    differs = []
    if not check:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
    for key in ("tablet", "phone"):
        compressed, raw_size, nodes = render(data[key])
        path = OUT_DIR / (data[key]["name"] + ".tosc")
        controls = (nodes - 2 - len(data[key]["pages"])) // 2
        if check:
            if not path.exists() or path.read_bytes() != compressed:
                differs.append(str(path.relative_to(ROOT)))
            continue
        path.write_bytes(compressed)
        print("%s: %d bytes written, %d bytes decompressed, %d nodes (%d controls and as many labels)" % (
            path.relative_to(ROOT), len(compressed), raw_size, nodes, controls))
    if check:
        if differs:
            sys.exit("generate.py --check: differs from layout.lua: " + ", ".join(differs)
                     + " (run python3 tools/touchosc/generate.py)")
        print("generate.py --check: both files match layout.lua")


if __name__ == "__main__":
    main()
