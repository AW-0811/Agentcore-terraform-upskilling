import stat
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"

# uv generates console launchers for the build host, even with Linux wheels.
LINUX_OTEL_LAUNCHER = """#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from opentelemetry.instrumentation.auto_instrumentation import run

if __name__ == "__main__":
    sys.exit(run())
"""


def main() -> None:
    DIST.mkdir(exist_ok=True)
    with TemporaryDirectory(dir=DIST) as temp:
        temp_path = Path(temp)
        package = temp_path / "package"
        requirements = temp_path / "requirements.txt"
        subprocess.run(
            [
                "uv",
                "export",
                "--locked",
                "--no-dev",
                "--no-emit-project",
                "--output-file",
                str(requirements),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                "uv",
                "pip",
                "install",
                "--python-platform",
                "aarch64-manylinux2014",
                "--python-version",
                "3.13",
                "--only-binary",
                ":all:",
                "--target",
                str(package),
                "-r",
                str(requirements),
            ],
            cwd=ROOT,
            check=True,
        )

        staged_zip = temp_path / "agent.zip"
        with ZipFile(staged_zip, "w") as archive:
            for name in ("main.py", "triage.py"):
                add_file(archive, name, (ROOT / name).read_bytes())
            for path in sorted(package.rglob("*")):
                relative = path.relative_to(package)
                if relative.parts[0] == "bin" or "__pycache__" in relative.parts:
                    continue
                if path.is_file():
                    data = path.read_bytes()
                    if relative.name == "RECORD" and relative.parent.name.endswith(
                        ".dist-info"
                    ):
                        data = b"".join(
                            line
                            for line in data.splitlines(keepends=True)
                            if not line.startswith(b"bin/")
                        )
                    add_file(archive, relative.as_posix(), data)
            add_file(
                archive,
                "bin/opentelemetry-instrument",
                LINUX_OTEL_LAUNCHER.encode(),
                executable=True,
            )
        staged_zip.replace(DIST / "agent.zip")
    print("Built dist/agent.zip")


def add_file(
    archive: ZipFile, name: str, data: bytes, *, executable: bool = False
) -> None:
    info = ZipInfo(name)
    info.create_system = 3
    info.compress_type = ZIP_DEFLATED
    permissions = 0o755 if executable else 0o644
    info.external_attr = (stat.S_IFREG | permissions) << 16
    archive.writestr(info, data)


if __name__ == "__main__":
    main()
