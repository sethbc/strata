### Fixed
- A file that vanished after it was chosen, followed by four quick bad loads into the same buffer, no longer leaves the buffer stuck waiting under the vanished file's name and then unsettled. The buffer is now empty, the header shows `buf <n> load failed`, and the file is no longer remembered. Two rarer timings are fixed too (#1040, below).
