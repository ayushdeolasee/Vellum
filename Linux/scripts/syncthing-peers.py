"""Opt-in transport for roundtrip-e2e.sh. All daemon state dies with the containers."""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
import xml.etree.ElementTree as ET


def docker(*args, **kwargs):
    return subprocess.run(["docker", "--context", "colima-vellum", *map(str, args)],
                          check=True, **kwargs)


def output(*args):
    return docker(*args, capture_output=True, text=True).stdout.strip()


def eventually(label, predicate, timeout=100):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.3)
    raise TimeoutError(label)


class Peer:
    def __init__(self, name, role, root, network, binary, cleanup, volume=None):
        self.name = name
        self.role = role
        self.library = root / role
        self.library.mkdir()
        (self.library / ".stfolder").mkdir()
        self.path = "/s9/live/linux" if volume else "/library"
        mounts = ["--mount", f"type=volume,source={volume},destination=/s9/live"] if volume else []
        docker("run", *mounts, "-d", "--pull", "never", "--network", network, "--name", name,
               "--user", "0", "--cpus", "1", "--env", "STNOUPGRADE=1", "--env", "STNODEFAULTFOLDER=1",
               "vellum-linux-dev:6.4.3", "sleep", "infinity")
        cleanup.callback(docker, "rm", "-fv", name)
        self.run("mkdir", "-p", self.path)
        docker("cp", binary, name + ":/tmp/syncthing")
        self.run("chmod", "755", "/tmp/syncthing")
        self.run("/tmp/syncthing", "generate", "--home=/tmp/config")
        self.config = ET.fromstring(output("exec", name, "cat", "/tmp/config/config.xml"))
        self.device = self.config.find("device").attrib["id"]
        self.api_key = self.config.findtext("gui/apikey")

    def run(self, *args):
        docker("exec", self.name, *args)

    def export(self):
        # Only the synthetic daemon's library is copied. Colima needs no host mounts.
        shutil.rmtree(self.library)
        self.library.mkdir()
        docker("cp", self.name + ":" + self.path + "/.", self.library)

    def install(self):
        scratch = "/tmp/snapshot-" + uuid.uuid4().hex
        docker("cp", self.library, self.name + ":" + scratch)
        # Keep the marker continuously present while scanners are running.
        self.run("python3", "-c", """
import pathlib, shutil, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for path in target.rglob('*'):
    relative = path.relative_to(target)
    if relative.parts[0] != '.stfolder' and path.is_file() and not (source / relative).exists():
        path.unlink()
shutil.copytree(source, target, dirs_exist_ok=True)
shutil.rmtree(source)
""", scratch, self.path)

    def start(self, other):
        assert other.device != self.device
        for item in self.config.findall("folder"):
            self.config.remove(item)
        devices = self.config.findall("device")
        assert [node.get("id") for node in devices] == [self.device]
        remote = ET.SubElement(self.config, "device", id=other.device, name=other.role)
        ET.SubElement(remote, "address").text = f"tcp://{other.name}:22000"
        folder = ET.SubElement(self.config, "folder", id="synthetic", path=self.path,
                               type="sendreceive", rescanIntervalS="1", fsWatcherEnabled="false", ignorePerms="true")
        for device in (self.device, other.device):
            ET.SubElement(folder, "device", id=device)
        options = self.config.find("options")
        for key, value in {"listenAddress": "tcp://0.0.0.0:22000", "globalAnnounceEnabled": "false",
                           "localAnnounceEnabled": "false", "relaysEnabled": "false", "natEnabled": "false",
                           "startBrowser": "false", "urAccepted": "-1", "autoUpgradeIntervalH": "0",
                           "crashReportingEnabled": "false", "reconnectionIntervalS": "1"}.items():
            for node in options.findall(key):
                options.remove(node)
            ET.SubElement(options, key).text = value
        self.config.find("gui/address").text = "127.0.0.1:8384"
        docker("exec", "-i", self.name, "sh", "-c", "cat > /tmp/config/config.xml",
               input=ET.tostring(self.config))
        self.launch()

    def launch(self):
        docker("exec", "-d", self.name, "sh", "-c",
               "exec /tmp/syncthing serve --home=/tmp/config --no-browser --no-restart > /tmp/daemon.log 2>&1")

    def api(self, path, method="GET"):
        script = ("import urllib.request as u,sys; "
                  "r=u.Request('http://127.0.0.1:8384/rest/'+sys.argv[1],"
                  "headers={'X-API-Key':sys.argv[2]},method=sys.argv[3]); "
                  "print(u.urlopen(r,timeout=10).read().decode())")
        return output("exec", self.name, "python3", "-c", script, path, self.api_key, method)

    def ready(self):
        try:
            return json.loads(self.api("system/status"))["myID"] == self.device
        except subprocess.CalledProcessError:
            return False

    def connection(self, peer):
        connections = json.loads(self.api("system/connections"))["connections"]
        return connections.get(peer.device, {})

    def connected(self, peer):
        return self.connection(peer).get("connected", False)

    def up_to_date(self, other):
        state = json.loads(self.api("db/status?folder=synthetic"))
        completion = json.loads(self.api("db/completion?folder=synthetic&device=" + other.device))
        return (state["state"] == "idle" and state["globalFiles"] > 0 and state["needTotalItems"] == 0
                and completion["completion"] == 100 and completion["needItems"] == 0)

    def scan(self):
        self.api("db/scan?folder=synthetic", "POST")


def run(stage, build_container, package, live):
    opts = ["swift", "test", "-j", "2", "--skip-build", "--force-resolved-versions",
            "--filter", "CrossPlatformRoundTripTests/exchange"]
    with ExitStack() as cleanup:
        root = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix="daemon-peers-", dir=stage)))
        (root / ".synthetic-s9").write_text("synthetic\n")
        token = "vellum-s9-" + uuid.uuid4().hex
        binary = os.environ.get("VELLUM_SYNCTHING_BINARY")
        if not binary:
            image = os.environ.get("VELLUM_SYNCTHING_IMAGE", "syncthing/syncthing:1.30.0")
            donor = output("create", "--pull", "never", "--network", "none", image)
            cleanup.callback(docker, "rm", "-v", donor)
            binary = root / "syncthing"
            docker("cp", donor + ":/bin/syncthing", binary)
        docker("network", "create", "--internal", token)
        cleanup.callback(docker, "network", "rm", token)
        mac = Peer(token + "-a", "mac", root, token, binary, cleanup)
        volume = output("inspect", "--format",
                        '{{range .Mounts}}{{if eq .Destination "/s9/live"}}{{.Name}}{{end}}{{end}}',
                        build_container) if live else None
        if live and not volume:
            raise RuntimeError("Missing disposable live library volume")
        linux = Peer(token + "-b", "linux", root, token, binary, cleanup, volume)
        if live:
            docker("cp", root / ".synthetic-s9", build_container + ":/s9/live/")
        container_root = "/s9/" + token
        docker("exec", build_container, "mkdir", "-p", container_root)
        docker("cp", root / ".synthetic-s9", build_container + ":" + container_root + "/")

        def phase(peer, step):
            env = {"VELLUM_S9_PHASE": step, "VELLUM_S9_PEER": peer.role}
            verify_only = step.startswith("verify-")
            if peer is mac:
                env["VELLUM_S9_SANDBOX"] = str(root)
                if step in ("mac-edit", "recover"):
                    # These two phases must exercise the shipping Mac scratchpad
                    # save and typed merge policy. Keep the Debug host isolated.
                    project = Path(package).parents[1] / "Vellum.xcodeproj"
                    derived = os.environ.get("VELLUM_S9_DERIVED_DATA", str(stage / "mac-debug"))
                    command = ["xcodebuild", "-project", project, "-scheme", "Vellum Mac",
                               "-configuration", "Debug", "-destination", "platform=macOS",
                               "-derivedDataPath", derived, "-jobs", "2", "-parallel-testing-enabled", "NO",
                               "OTHER_SWIFT_FLAGS=$(inherited) -j2", "-disableAutomaticPackageResolution", "-skipPackageUpdates",
                               "-only-testing:VellumMacTests/CrossPlatformRoundTripTests", "test"]
                    env.update({"TEST_RUNNER_" + k: v for k, v in env.items()})
                else:
                    command = [*opts, "--package-path", package, "--scratch-path", stage / "build"]
                if verify_only:
                    # SwiftPM cannot nest its manifest sandbox under Seatbelt.
                    # Keep the outer read-only policy active for all children.
                    command.append("--disable-sandbox")
                    command = ["sandbox-exec", "-D", "LIBRARY=" + str(peer.library.resolve()),
                               "-p", '(version 1)(allow default)(deny file-write* (subpath (param "LIBRARY")))',
                               *command]
                subprocess.run(command, env={**os.environ, **env, "GIT_ALLOW_PROTOCOL": "file"}, check=True)
                assert (root / ("completed-" + step)).read_text() == step
            else:
                # Only connected recovery writes directly into the daemon volume.
                on_volume = live and step == "recover"
                sandbox = "/s9/live" if on_volume else container_root
                target = sandbox + "/linux"
                if not on_volume:
                    docker("exec", build_container, "python3", "-c",
                           "import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1]); "
                           "shutil.rmtree(p) if p.exists() else None; p.mkdir()", target)
                    docker("cp", str(peer.library) + "/.", build_container + ":" + target)
                env["VELLUM_S9_SANDBOX"] = sandbox
                args = [arg for k, v in env.items() for arg in ("-e", k + "=" + v)]
                guard = []
                if verify_only:
                    # The test runner owns its scratch path and phase receipt, but
                    # cannot write, chmod or chown the exported library.
                    docker("exec", build_container, "chown", "-R", "65534:65534", target)
                    docker("exec", build_container, "chmod", "-R", "a+rX,a-w", target)
                    guard = ["setpriv", "--bounding-set=-all", "--no-new-privs"]
                docker("exec", *args, build_container, *guard, *opts,
                       "--package-path", "/s9/pkg", "--scratch-path", "/s9/build")
                assert output("exec", build_container, "cat", sandbox + "/completed-" + step) == step
                if on_volume:
                    return
                # No bind mount: replace the staging tree with the exact writer
                # output, including the removal of resolved conflict siblings.
                shutil.rmtree(peer.library)
                peer.library.mkdir()
                docker("cp", build_container + ":" + target + "/.", peer.library)
                if verify_only:
                    for directory in [peer.library, *peer.library.rglob("*")]:
                        if directory.is_dir():
                            directory.chmod(0o700)

        phase(mac, "prepare")
        phase(linux, "prepare")
        phase(mac, "seed")
        peers = [mac, linux]
        for peer in peers:
            (peer.library / ("local-" + peer.role)).write_text(peer.role)
        ignore_files = {p.role: (p.library / ".stignore").read_bytes() for p in peers}

        def check_private(peer, other):
            assert (peer.library / ".stignore").read_bytes() == ignore_files[peer.role]
            assert (peer.library / ("local-" + peer.role)).read_text() == peer.role
            assert not (peer.library / ("local-" + other.role)).exists()
            tmp = peer.library / ".vellum/index.json.tmp"
            if peer is mac:
                assert tmp.read_bytes() == bytes([42])
            else:
                assert not tmp.exists()

        print(output("exec", mac.name, "/tmp/syncthing", "--version"), flush=True)
        def ledger(peer, include_private=False):
            files = {}
            for file in peer.library.rglob("*"):
                path = file.relative_to(peer.library)
                if not file.is_file():
                    continue
                if not include_private and (path.parts[0] in (".stignore", ".stfolder", "local-" + peer.role)
                                            or str(path) == ".vellum/index.json.tmp"):
                    continue
                name = unicodedata.normalize("NFC", str(path))
                assert name not in files, f"Duplicate archive spelling: {name}"
                files[name] = hashlib.sha256(file.read_bytes()).hexdigest()
            return files
        try:
            for peer in peers:
                peer.install()
            mac.start(linux)
            linux.start(mac)
            for peer in peers:
                eventually(peer.role + " REST startup", peer.ready)
            eventually("initial peer connection", lambda: mac.connected(linux) and linux.connected(mac))
            mac.scan()
            def baseline():
                linux.export()
                for file in mac.library.rglob("*"):
                    path = file.relative_to(mac.library)
                    if file.is_file() and path.parts[0] not in (".stignore", ".stfolder", "local-mac") and path.name != "index.json.tmp":
                        dest = linux.library / path
                        if not dest.exists() or file.read_bytes() != dest.read_bytes():
                            return False
                return True
            eventually("first complete Mac library", baseline)
            eventually("common indexed baseline", lambda: mac.up_to_date(linux) and linux.up_to_date(mac))
            assert not (linux.library / ".vellum/index.json.tmp").exists()
            assert (linux.library / ".stignore").read_bytes() != (mac.library / ".stignore").read_bytes()
            print("Synthetic peers indexed the same baseline and retained their own .stignore.", flush=True)
            # Disconnect at the bridge, while both databases and scanners remain live.
            mac.api("system/pause?device=" + linux.device, "POST")
            linux.api("system/pause?device=" + mac.device, "POST")
            docker("network", "disconnect", token, linux.name)
            eventually("both devices offline", lambda: not mac.connected(linux) and not linux.connected(mac))
            print("Both fresh device IDs disconnected:", mac.device[:7], linux.device[:7], flush=True)
            for peer in peers:
                peer.export()
            phase(mac, "mac-edit")
            phase(linux, "linux-edit")
            for peer in peers:
                peer.install()
                peer.scan()
                assert not list(peer.library.rglob("*.sync-conflict-*"))
            docker("network", "connect", token, linux.name)
            mac.api("system/resume?device=" + linux.device, "POST")
            linux.api("system/resume?device=" + mac.device, "POST")
            eventually("both peers reconnected", lambda: mac.connected(linux) and linux.connected(mac))
            def six_siblings():
                for peer in peers:
                    peer.export()
                return all(len(list(p.library.rglob("*.sync-conflict-*"))) == 6 for p in peers)
            eventually("six actual conflict siblings at both peers", six_siblings)
            eventually("both conflict directories fully replicated", lambda: mac.up_to_date(linux) and linux.up_to_date(mac))
            print("Six real conflict siblings replicated to each peer.", flush=True)
            if live:
                def sessions():
                    connections = [mac.connection(linux), linux.connection(mac)]
                    assert all(c["connected"] and c["startedAt"] for c in connections)
                    return [c["startedAt"] for c in connections]
                started = sessions()
                phase(linux, "recover")
                assert sessions() == started
                linux.scan()
                def delivered():
                    mac.export()
                    linux.export()
                    files = ledger(mac)
                    return (not any(".sync-conflict-" in p for p in files)
                            and files == ledger(linux) and any("/conflicts/" in p for p in files)
                            and mac.up_to_date(linux) and linux.up_to_date(mac))
                eventually("live Linux recovery delivered to Mac", delivered)
                assert sessions() == started
                print("Connected Linux resolver archived six conflicts on the live daemon volume; "
                      "Mac received the recovery before restart.", flush=True)
            # The independent pass consumes two frozen copies with the shipping Mac
            # and portable policies. The live pass restarts already-converged disks.
            for peer in peers:
                docker("stop", "-t", "1", peer.name)
            if not live:
                for peer in peers:
                    peer.export()
                    phase(peer, "recover")
            for peer in peers:
                docker("start", peer.name)
                if not live:
                    peer.install()
                peer.launch()
                eventually(peer.role + " recovery restart", peer.ready)
                peer.scan()
            mac.api("system/resume?device=" + linux.device, "POST")
            linux.api("system/resume?device=" + mac.device, "POST")
            def restored():
                for peer in peers:
                    peer.export()
                left, right = ledger(mac), ledger(linux)
                return (left == right and not any(".sync-conflict-" in path for path in left)
                        and mac.connected(linux) and linux.connected(mac)
                        and mac.up_to_date(linux) and linux.up_to_date(mac))
            eventually("restored canonical and archived bytes on both peers", restored)
            for peer, other in [(mac, linux), (linux, mac)]:
                check_private(peer, other)
                # Verify an export taken after restart. Neither verifier has a path
                # back to the daemon directory. Also reject edits to the export.
                before = ledger(peer, include_private=True)
                phase(peer, "verify-preserved" if live else "verify-merged")
                assert ledger(peer, include_private=True) == before
                files = ledger(peer)
                print(f"{peer.role}: connected, idle, zero needed, {len(files)} identical files, "
                      f"{sum('/conflicts/' in p for p in files)} archived, zero unresolved siblings.", flush=True)
        except BaseException:
            for peer in peers:
                subprocess.run(["docker", "--context", "colima-vellum", "exec", peer.name, "tail", "-30", "/tmp/daemon.log"])
            raise
        print("Both real Syncthing peers recovered their offline versions.")


if __name__ == "__main__":
    if os.environ.get("VELLUM_SYNCTHING_E2E") != "1":
        sys.exit("Set VELLUM_SYNCTHING_E2E=1 and use roundtrip-e2e.sh")
    for live in (False, True):
        run(Path(sys.argv[1]), sys.argv[2], sys.argv[3], live)
