"""Exercise the root init callback embedded in each shipped panel."""
import shutil
import subprocess
import unittest
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

PANELS = Path(__file__).resolve().parents[2] / "extras/touchosc"


class PanelStartupTest(unittest.TestCase):
    def test_startup_requests_current_values_on_connection_one(self):
        lua = shutil.which("lua") or shutil.which("luajit")
        for name in ("strata-phone", "strata-tablet"):
            with self.subTest(panel=name):
                panel = ET.fromstring(zlib.decompress((PANELS / (name + ".tosc")).read_bytes()))
                script = panel.findtext("./node/properties/property[@type='s'][key='script']/value", "")
                result = subprocess.run([lua, "-"], input="""
function sendOSC(path, connections, ...)
  assert(type(connections) == "table" and connections[1] == true)
  for index, enabled in pairs(connections) do assert(index == 1 or not enabled) end
  assert(select("#", ...) == 0)
  print(path)
end
""" + script + "\nif init then init() end\n", text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.splitlines(), ["/strata/hello"])


if __name__ == "__main__":
    unittest.main()
