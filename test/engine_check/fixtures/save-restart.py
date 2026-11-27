"""Two sclang processes contend for one WAV after the first dies at handoff (Linux)."""
import ctypes
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import wave


FIXTURES = Path(__file__).resolve().parent
FRAMES = 4096


def write_input(path, polarity):
    # Different on each side and across frames. Both writers have the same
    # format and length, so the comparison must distinguish their samples.
    pcm = b"".join(struct.pack("<hh", polarity * (i + 64), -polarity * (2 * i + 32))
                   for i in range(FRAMES))
    with wave.open(str(path), "wb") as wav:
        wav.setparams((2, 2, 48000, FRAMES, "NONE", "not compressed"))
        wav.writeframes(pcm)
    return pcm


def check_pcm(path, expected, stage):
    with wave.open(str(path), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) != (2, 2, 48000, FRAMES):
            raise AssertionError(f"{stage}: {path.name} has unexpected WAV parameters: {wav.getparams()}")
        if wav.readframes(FRAMES) != expected:
            raise AssertionError(f"{stage}: {path.name} differs from the expected stereo PCM")


def start_writer(sclang, directory, role, writers):
    temp = directory / role
    temp.mkdir()
    # Keep both sockets bound during selection so sclang cannot claim its
    # own scsynth's port when it starts alongside the outer runner.
    with socket.socket(type=socket.SOCK_DGRAM) as language, socket.socket(type=socket.SOCK_DGRAM) as server:
        language.bind(("", 0))
        server.bind(("", 0))
        language_port = str(language.getsockname()[1])
        server_port = str(server.getsockname()[1])
    env = dict(os.environ, STRATA_CHECK_TMPDIR=str(temp), STRATA_RESTART_DIR=str(directory),
               STRATA_SC_PORT=server_port, STRATA_ENGINE_CHECK_AREAS="files")
    if role == "old":
        env["PATH"] = str(directory / "bin") + os.pathsep + env["PATH"]
    config = Path(os.environ["STRATA_CHECK_TMPDIR"]) / "sclang_conf.yaml"
    with (temp / "output").open("wb") as log:
        process = subprocess.Popen([sclang, "-u", language_port, "-l", config, FIXTURES.parents[1] / "engine_check.scd",
                                    "save-restart", role], cwd=temp, env=env, stdout=log, stderr=log)
    writers.append((process, int(server_port), temp / "scsynth.pid"))
    return process


def wait_for_file(process, directory, pattern):
    deadline = time.monotonic() + 35
    while not (matches := list(directory.glob(pattern))):
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"restart: writer did not reach {pattern}")
        time.sleep(0.02)
    return matches[0]


def quit_server(port, pid):
    # waitpid establishes that this is our adopted child before any send.
    reaped, status = os.waitpid(pid, os.WNOHANG)
    if not reaped:
        with socket.socket(type=socket.SOCK_DGRAM) as client:
            # SC 3.14 can segfault in World_Cleanup when /quit unloads a
            # live graph's UGens. Free the root group's nodes and confirm the
            # preceding command has run, on the server the dead sclang owned.
            client.connect(("127.0.0.1", port))
            client.settimeout(3)
            free = b"/g_freeAll\0\0,i\0\0" + struct.pack(">i", 0)
            sync = b"/sync\0\0\0,i\0\0" + struct.pack(">i", 1)
            bundle = b"#bundle\0" + struct.pack(">Q", 1)
            for message in (free, sync):
                bundle += struct.pack(">i", len(message)) + message
            client.send(bundle)
            if client.recv(64) != b"/synced\0,i\0\0" + struct.pack(">i", 1):
                raise RuntimeError(f"restart: scsynth {pid} did not confirm freeing its nodes")
            client.send(b"/quit\0\0\0,\0\0\0")
        deadline = time.monotonic() + 3
        while not reaped:
            if time.monotonic() > deadline:
                raise RuntimeError(f"restart: scsynth {pid} did not quit")
            time.sleep(0.02)
            reaped, status = os.waitpid(pid, os.WNOHANG)
    if status:
        raise RuntimeError(f"restart: scsynth {pid} exited with {os.waitstatus_to_exitcode(status)}")


def stop_children(writers):
    errors = []
    for process, port, pid_file in writers:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if pid_file.exists():
            try:
                quit_server(port, int(pid_file.read_text()))
            except ChildProcessError:
                pass  # sclang or the supervisor already reaped its server
            except (ValueError, OSError, RuntimeError) as error:
                errors.append(str(error))

    # As a Linux subreaper, even grandchildren orphaned by SIGKILL become
    # our children. Reap one layer at a time without addressing other runs.
    children = Path("/proc/thread-self/children")
    deadline = time.monotonic() + 5
    while pids := children.read_text().split():
        for pid in map(int, pids):
            if os.waitpid(pid, os.WNOHANG)[0] == 0:
                os.kill(pid, signal.SIGKILL)
        if time.monotonic() > deadline:
            raise RuntimeError("restart: timed out cleaning up child processes")
        time.sleep(0.02)
    if errors:
        raise RuntimeError("; ".join(errors))


def run(sclang, directory, writers):
    directory.mkdir()
    (directory / "bin").mkdir()
    shutil.copy(FIXTURES / "hold-wav-mv.sh", directory / "bin/mv")
    (directory / "bin/mv").chmod(0o700)
    old_pcm = write_input(directory / "old.wav", 1)
    new_pcm = write_input(directory / "new.wav", -1)
    destination = directory / "held-restart.wav"
    barrier = directory / "held-restart.wav.barrier"
    old = start_writer(sclang, directory, "old", writers)
    entered = wait_for_file(old, barrier, "in.*")
    child = int(entered.suffix[1:])
    fd = os.pidfd_open(child)
    try:
        part = Path((barrier / "source").read_text().strip())
        check_pcm(part, old_pcm, "at fallback handoff")
        old.kill()
        if old.wait(timeout=5) != -signal.SIGKILL:
            raise AssertionError("restart: old sclang did not exit by SIGKILL")
        poll = select.poll()
        poll.register(fd, select.POLLIN)
        _, port, pid_file = writers[-1]
        quit_server(port, int(pid_file.read_text()))
        writers.pop()
        if poll.poll(0):
            raise AssertionError("restart: the fallback did not survive sclang and its server")

        new = start_writer(sclang, directory, "new", writers)
        wait_for_file(new, directory, "published")
        check_pcm(destination, new_pcm, "before releasing the old fallback")
        if poll.poll(0):
            raise AssertionError("restart: fallback exited before its release")
        (directory / "held-restart.wav.release").touch()
        if not poll.poll(5000) or not (barrier / f"out.{child}").exists():
            raise AssertionError("restart: old fallback failed to attempt its rename and exit")
        check_pcm(destination, new_pcm, "after the old fallback exited")
        if new.poll() is not None:
            raise AssertionError("restart: successor exited before the old fallback")
        (directory / "verified").touch()
        if new.wait(timeout=10) != 0:
            raise AssertionError("restart: successor sclang failed")
        if "ENGINE CHECK PASSED" not in (directory / "new/output").read_text().splitlines():
            raise AssertionError("restart: successor check did not finish")
    finally:
        os.close(fd)


if __name__ == "__main__":
    # PR_SET_CHILD_SUBREAPER. No process from another check can be adopted.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0):
        raise OSError(ctypes.get_errno(), "could not become a subreaper")
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    directory = Path(sys.argv[2])
    writers = []
    try:
        run(sys.argv[1], directory, writers)
    finally:
        primary = sys.exc_info()[1]
        cleanup_error = None
        try:
            stop_children(writers)
        except Exception as error:
            cleanup_error = error
        # Relay diagnostics to the shard's usual warning/error checks. Its
        # success marker must come only from the outer runner.
        for log in sorted(directory.glob("*/output")):
            print(f"--- restart {log.parent.name} sclang ---")
            for line in log.read_text(errors="replace").splitlines():
                if line.startswith(("ok ", "teardown ", "area ", "compiled ")) or line == "ENGINE CHECK PASSED":
                    print("restart:", line)
                else:
                    print(line)

        if cleanup_error is not None:
            if primary is None:
                raise cleanup_error
            sys.stdout.flush()
            print(f"restart: cleanup also failed: {cleanup_error}", file=sys.stderr)
