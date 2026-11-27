"""Verify the shipped TouchOSC panels and exercise their startup and scene feedback."""
import shutil
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

import generate

PANELS = Path(__file__).resolve().parents[2] / "extras/touchosc"


def verified_panels(directory):
    layouts = generate.read_layout()
    panels = {}
    for size in ("phone", "tablet"):
        layout = layouts[size]
        name = layout["name"]
        expected, _, _ = generate.render(layout)
        path = directory / (name + ".tosc")
        with path.open("rb") as shipped:
            if shipped.read(len(expected) + 1) != expected:
                raise AssertionError(path.name + " differs from the generator")
        panels[name] = ET.fromstring(zlib.decompress(expected))
    return panels


class PanelStartupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panels = verified_panels(PANELS)

    def test_startup_and_current_scene_feedback(self):
        lua = shutil.which("lua") or shutil.which("luajit")
        for name, panel in self.panels.items():
            with self.subTest(panel=name):
                script = panel.findtext("./node/properties/property[@type='s'][key='script']/value", "")
                buttons = [node for node in panel.findall(".//node[@type='BUTTON']")
                           if node.findtext("properties/property[key='name']/value", "").startswith("scene ")]
                self.assertEqual(len(buttons), 16)
                for index, button in enumerate(buttons, 1):
                    (message,) = button.findall("messages/osc")
                    self.assertEqual(message.findtext("path/partial/value"), "/strata/scene")
                    self.assertEqual(message.findtext("arguments/partial/value"), str(index))
                    self.assertEqual(message.findtext("triggers/trigger/condition"), "RISE")
                    self.assertEqual((message.findtext("send"), message.findtext("receive")), ("1", "0"))
                labels = [node for node in panel.findall(".//node[@type='LABEL']")
                          if node.findtext("properties/property[key='name']/value") == "label current scene"]
                self.assertEqual(len(labels), 1, "one current scene indicator")
                label = labels[0]
                self.assertEqual(label.findtext("properties/property[key='interactive']/value"), "0")
                self.assertEqual(label.findall("messages/osc"), [])
                self.assertEqual(label.findtext("values/value[key='text']/default"), "current scene —")
                result = subprocess.run([lua, "-"], input="""
local display = {values = {text = "previous session"}}
self = {findByName = function(_, name, recursive)
  assert(name == "label current scene" and recursive)
  return display
end}
function sendOSC(path, connections, ...)
  assert(type(connections) == "table" and connections[1] == true)
  for index, enabled in pairs(connections) do assert(index == 1 or not enabled) end
  assert(select("#", ...) == 0)
  print(path)
end
""" + script + """
init()
assert(display.values.text == "current scene —")
local function receive(path, value, on_connection_one)
  onReceiveOSC({path, {{tag="f", value=value}}}, {on_connection_one})
end
receive("/strata/scene", 3, true)
assert(display.values.text == "current scene 3")
receive("/strata/scene", 6, false)
receive("/strata/patterns", 1, true)
assert(display.values.text == "current scene 3")
receive("/strata/scene", 16, true)
assert(display.values.text == "current scene 16")
init()
assert(display.values.text == "current scene —")
""", text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.splitlines(), ["/strata/hello", "/strata/hello"])


class PanelVerificationTest(unittest.TestCase):
    def test_panel_only_change_is_refused_before_callbacks(self):
        # A harmless stale second panel must stop startup for both.
        with tempfile.TemporaryDirectory() as temp:
            panels = Path(temp)
            shutil.copyfile(PANELS / "strata-phone.tosc", panels / "strata-phone.tosc")
            (panels / "strata-tablet.tosc").write_bytes(b"out of date")
            with self.assertRaisesRegex(AssertionError, "strata-tablet"):
                verified_panels(panels)


if __name__ == "__main__":
    unittest.main()
