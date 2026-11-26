import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_rootfs", ROOT / "scripts/build_rootfs.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class BuilderMatrixTests(unittest.TestCase):
    def test_every_supported_distribution_has_a_preset_or_explicit_source(self):
        recipes = list((ROOT / "recipes").glob("*-aarch64.json"))
        names = {__import__("json").loads(p.read_text())["distribution"] for p in recipes}
        expected = set(builder.OCI) | {"Devuan"}
        self.assertEqual(names, expected)

    def test_arm64_oci_sources_are_pinned_to_known_tags(self):
        self.assertEqual(builder.OCI["Debian"]["trixie"], "debian:trixie-slim")
        self.assertEqual(builder.OCI["Void Linux"]["rolling"], "ghcr.io/void-linux/void-glibc:latest")
        self.assertEqual(builder.OCI["Arch Linux ARM"]["rolling"], "menci/archlinuxarm:latest")

    def test_native_package_manager_adapters(self):
        cases = {
            "Debian": "apt-get update",
            "Devuan": "apt-get update",
            "Ubuntu": "apt-get update",
            "Kali Linux": "apt-get update",
            "Alpine": "apk add",
            "Arch Linux ARM": "pacman -S",
            "Fedora": "dnf install",
            "openSUSE Leap": "zypper",
            "openSUSE Tumbleweed": "zypper",
            "Gentoo": "emerge",
            "Void Linux": "xbps-install",
        }
        inits = {"Alpine":"OpenRC", "Devuan":"SysVinit", "Void Linux":"runit", "Gentoo":"OpenRC", "Arch Linux ARM":"systemd"}
        for distro, marker in cases.items():
            init = inits.get(distro, "systemd")
            self.assertIn(marker, builder.package_command(distro, ["curl"], False, init))

    def test_package_parser_rejects_shell_metacharacters(self):
        self.assertIsNone(builder.PACKAGE.fullmatch("curl; touch /tmp/oops"))
        self.assertIsNotNone(builder.PACKAGE.fullmatch("net-misc/curl"))

if __name__ == "__main__":
    unittest.main()
