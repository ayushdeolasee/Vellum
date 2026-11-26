"""Opt-in transport for roundtrip-e2e.sh. All daemon state dies with the containers."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
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
    def __init__(self, name, role, root, network, binary, cleanup):
        self.name = name
        self.role = role
        self.library = root / role
        self.library.mkdir()
        docker("run", "-d", "--pull", "never", "--network", network, "--name", name,
               "--user", "0", "--cpus", "1", "--env", "STNOUPGRADE=1", "--env", "STNODEFAULTFOLDER=1",
               "--mount", f"type=bind,src={self.library},dst=/library",
               "vellum-linux-dev:6.4.3", "sleep", "infinity")
        cleanup.callback(docker, "rm", "-fv", name)
        docker("cp", binary, name + ":/tmp/syncthing")
        self.run("chmod", "755", "/tmp/syncthing")
        self.run("/tmp/syncthing", "generate", "--home=/tmp/config")
        self.config = ET.fromstring(output("exec", name, "cat", "/tmp/config/config.xml"))
        self.device = self.config.find("device").attrib["id"]
        self.api_key = self.config.findtext("gui/apikey")

    def run(self, *args):
        docker("exec", self.name, *args)

    def start(self, other):
        assert other.device != self.device
        for item in self.config.findall("folder"):
            self.config.remove(item)
        devices = self.config.findall("device")
        assert [node.get("id") for node in devices] == [self.device]
        remote = ET.SubElement(self.config, "device", id=other.device, name=other.role)
        ET.SubElement(remote, "address").text = f"tcp://{other.name}:22000"
        folder = ET.SubElement(self.config, "folder", id="synthetic", path="/library",
                               type="sendreceive", rescanIntervalS="1", fsWatcherEnabled="false")
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

    def connected(self, peer):
        connections = json.loads(self.api("system/connections"))["connections"]
        return connections.get(peer.device, {}).get("connected", False)

    def scan(self):
        self.api("db/scan?folder=synthetic", "POST")


def run(stage, build_container, package):
    opts = ["swift", "test", "-j", "2", "--skip-build", "--force-resolved-versions",
            "--filter", "CrossPlatformRoundTripTests/exchange"]
    with ExitStack() as cleanup:
        # The vellum profile shares the home directory; only these two newly
        # created data directories are mounted, never home or an app library.
        root = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix=".vellum-s9-", dir=Path.home())))
        (root / ".synthetic-s9").write_text("synthetic\n")
        token = "vellum-s9-" + uuid.uuid4().hex
        binary = os.environ.get("VELLUM_SYNCTHING_BINARY")
        if not binary:
            image = os.environ.get("VELLUM_SYNCTHING_IMAGE", "syncthing/syncthing:latest")
            donor = output("create", "--pull", "never", "--network", "none", image)
            cleanup.callback(docker, "rm", "-v", donor)
            binary = root / "syncthing"
            docker("cp", donor + ":/bin/syncthing", binary)
        docker("network", "create", "--internal", token)
        cleanup.callback(docker, "network", "rm", token)
        mac = Peer(token + "-a", "mac", root, token, binary, cleanup)
        linux = Peer(token + "-b", "linux", root, token, binary, cleanup)
        container_root = "/s9/daemon-test"
        docker("exec", build_container, "mkdir", "-p", container_root)
        docker("cp", root / ".synthetic-s9", build_container + ":" + container_root + "/")

        def phase(peer, step):
            env = {"VELLUM_S9_PHASE": step, "VELLUM_S9_PEER": peer.role}
            if peer is mac:
                env["VELLUM_S9_SANDBOX"] = str(root)
                subprocess.run([*opts, "--package-path", package, "--scratch-path", stage / "build"],
                               env={**os.environ, **env}, check=True)
                assert (root / ("completed-" + step)).read_text() == step
            else:
                # Export a fresh view each time. The build container has no network
                # and has no host mounts. Copy back only the writer's changes.
                target = container_root + "/linux"
                docker("exec", build_container, "mkdir", "-p", target)
                docker("cp", str(peer.library) + "/.", build_container + ":" + target)
                env["VELLUM_S9_SANDBOX"] = container_root
                args = [arg for k, v in env.items() for arg in ("-e", k + "=" + v)]
                docker("exec", *args, build_container, *opts, "--package-path", "/s9/pkg", "--scratch-path", "/s9/build")
                assert output("exec", build_container, "cat", container_root + "/completed-" + step) == step
                if step != "recover":
                    docker("cp", build_container + ":" + target + "/.", peer.library)

        phase(mac, "prepare")
        phase(linux, "prepare")
        phase(mac, "seed")
        peers = [mac, linux]
        try:
            mac.start(linux)
            linux.start(mac)
            for peer in peers:
                eventually(peer.role + " REST startup", peer.ready)
            eventually("initial peer connection", lambda: mac.connected(linux) and linux.connected(mac))
            mac.scan()
            def baseline():
                for file in mac.library.rglob("*"):
                    path = file.relative_to(mac.library)
                    if file.is_file() and path.parts[0] not in (".stignore", ".stfolder") and path.name != "index.json.tmp":
                        dest = linux.library / path
                        if not dest.exists() or file.read_bytes() != dest.read_bytes():
                            return False
                return True
            eventually("first complete Mac library", baseline)
            assert not (linux.library / ".vellum/index.json.tmp").exists()
            assert (linux.library / ".stignore").read_bytes() != (mac.library / ".stignore").read_bytes()
            # Disconnect at the bridge, while both databases and scanners remain live.
            docker("network", "disconnect", token, linux.name)
            eventually("both devices offline", lambda: not mac.connected(linux) and not linux.connected(mac))
            phase(mac, "mac-edit")
            phase(linux, "linux-edit")
            for peer in peers:
                peer.scan()
                assert not list(peer.library.rglob("*.sync-conflict-*"))
            docker("network", "connect", token, linux.name)
            eventually("both peers reconnected", lambda: mac.connected(linux) and linux.connected(mac))
            eventually("six actual conflict siblings at both peers",
                       lambda: all(len(list(p.library.rglob("*.sync-conflict-*"))) == 6 for p in peers))
            # Freeze the actual daemon outputs before independently consuming either side.
            for peer in peers:
                docker("stop", peer.name)
            for peer in peers:
                phase(peer, "recover")
        except BaseException:
            for peer in peers:
                subprocess.run(["docker", "--context", "colima-vellum", "exec", peer.name, "tail", "-30", "/tmp/daemon.log"])
            raise
        print("Both real Syncthing peers recovered their offline versions.")


if __name__ == "__main__":
    if os.environ.get("VELLUM_SYNCTHING_E2E") != "1":
        sys.exit("Set VELLUM_SYNCTHING_E2E=1 and use roundtrip-e2e.sh")
    run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
