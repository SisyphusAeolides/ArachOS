#!/usr/bin/env python3
"""Exercise the Calamares-to-Corinth transaction boundary without a target root."""

import importlib.util
import subprocess
import sys
import types
from pathlib import Path


class _Job:
    def __init__(self, configuration):
        self.configuration = configuration
        self.progress = []

    def setprogress(self, value):
        self.progress.append(value)


class _Storage:
    def __init__(self, values):
        self.values = values

    def contains(self, key):
        return key in self.values

    def value(self, key):
        return self.values[key]


def load_module(module_name, relative_path, calls, warnings):
    calamares = types.ModuleType("libcalamares")
    utils = types.ModuleType("libcalamares.utils")

    def run_target(command):
        calls.append(list(command))
        if "optional" in command:
            raise subprocess.CalledProcessError(17, command)

    utils.target_env_process_output = run_target
    utils.debug = lambda message: None
    utils.warning = warnings.append
    calamares.utils = utils
    sys.modules["libcalamares"] = calamares
    sys.modules["libcalamares.utils"] = utils

    path = Path(__file__).resolve().parents[1] / relative_path
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return calamares, module


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    calls = []
    warnings = []
    calamares, module = load_module(
        "arachos_packages",
        "archiso/airootfs/usr/lib/calamares/modules/arachos-packages/main.py",
        calls,
        warnings,
    )
    configuration = {
        "corinth": {
            "executable": "/usr/bin/corinth",
            "service-config": "/etc/corinth/service.toml",
            "service-signature": "/etc/corinth/service.toml.sig",
            "keyring": "/etc/arach/hwd/keys.toml",
        },
        "operations": [{"install": ["plasma-meta"]}],
    }
    calamares.job = _Job(configuration)
    calamares.globalstorage = _Storage(
        {"locale": "en_US", "packageOperations": [{"try_install": ["optional"]}]}
    )

    check(module.run() is None, "a successful critical package should pass")
    check(
        calls[0][:3] == ["/usr/bin/corinth", "install", "plasma-meta"],
        "install verb was not routed",
    )
    check(
        calls[0][-6:]
        == [
            "--config",
            "/etc/corinth/service.toml",
            "--config-signature",
            "/etc/corinth/service.toml.sig",
            "--keyring",
            "/etc/arach/hwd/keys.toml",
        ],
        "signed service arguments were not passed",
    )
    check(len(warnings) == 1 and "optional" in warnings[0], "optional failures should be reported")
    check(calamares.job.progress[-1] == 1.0, "Calamares progress did not finish")

    hardware = {
        "enabled": True,
        "executable": "/usr/bin/arach-hwd",
        "catalog-root": "/etc/arach/hwd/catalog",
        "profiles": "/etc/arach/hwd/catalog/profiles",
        "keyring": "/etc/arach/hwd/catalog/keys.toml",
        "catalog-lock": "/etc/arach/hwd/catalog/catalog.lock",
        "driver-abi": "1.0",
        "output": "/run/arach-installer/hardware-plan.toml",
        "require-target-profiles": True,
    }
    calamares_hwd, hwd = load_module(
        "arachos_hardware",
        "archiso/airootfs/usr/lib/calamares/modules/arachos-hardware/main.py",
        calls,
        warnings,
    )
    calls.clear()
    calamares_hwd.job = _Job(hardware)
    calamares_hwd.globalstorage = _Storage({})
    check(hwd.run() is None, "a signed hardware plan should pass")
    check(
        calls[0] == ["/usr/bin/mkdir", "-p", "/run/arach-installer"],
        "hardware output directory was not prepared",
    )
    check(
        calls[1][:10]
        == [
            "/usr/bin/arach-hwd",
            "plan",
            "--sysfs",
            "/sys",
            "--profiles",
            "/etc/arach/hwd/catalog/profiles",
            "--keyring",
            "/etc/arach/hwd/catalog/keys.toml",
            "--catalog-lock",
            "/etc/arach/hwd/catalog/catalog.lock",
        ],
        "Arach-HWD was not invoked with the signed catalog",
    )
    check("--require-target-profiles" in calls[1], "target profiles were not required")

    calls.clear()
    calamares.job = _Job(
        {
            "corinth": {
                "executable": "/usr/bin/corinth",
                "service-config": "/etc/corinth/service.toml",
                "service-signature": "/etc/corinth/service.toml.sig",
                "keyring": "/etc/arach/hwd/keys.toml",
                "hardware": {
                    "enabled": True,
                    "plan": "/run/arach-installer/hardware-plan.toml",
                    "catalog-root": "/etc/arach/hwd/catalog",
                    "profiles": "/etc/arach/hwd/catalog/profiles",
                    "catalog-lock": "/etc/arach/hwd/catalog/catalog.lock",
                    "keyring": "/etc/arach/hwd/catalog/keys.toml",
                    "work": "/var/cache/corinth/work",
                    "artifacts": "/var/cache/corinth/artifacts",
                    "state": "/var/lib/corinth",
                    "root": "/",
                },
            },
            "operations": [{"install": ["plasma-meta"]}],
        }
    )
    calamares.globalstorage = _Storage({"locale": "en"})
    check(module.run() is None, "hardware and desktop transactions should pass")
    check(
        calls[0][:10]
        == [
            "/usr/bin/corinth",
            "install",
            "--plan",
            "/run/arach-installer/hardware-plan.toml",
            "--profiles",
            "/etc/arach/hwd/catalog/profiles",
            "--catalog-lock",
            "/etc/arach/hwd/catalog/catalog.lock",
            "--keyring",
            "/etc/arach/hwd/catalog/keys.toml",
        ],
        "Corinth did not consume the Arach-HWD plan",
    )
    check(calls[1][1:3] == ["install", "plasma-meta"], "desktop package was not routed")

    calamares.job = _Job({"corinth": {}, "operations": [{"localInstall": ["/tmp/file"]}]})
    calamares.globalstorage = _Storage({"locale": "en"})
    error = module.run()
    check(error and "configuration error" in error[0], "local package files must be rejected")

    calamares.job = _Job({"corinth": {}, "operations": [{"install": ["--unsafe"]}]})
    error = module.run()
    check(error and "unsafe" in error[1], "unsafe package names must be rejected")

    calamares.job = _Job(
        {
            "corinth": {},
            "operations": [
                {"install": [{"package": "example", "pre-script": "touch /tmp/x"}]}
            ],
        }
    )
    calamares.globalstorage = _Storage({"locale": "en"})
    error = module.run()
    check(error and "scripts are disabled" in error[1], "package scripts must be rejected")
    print("validated Calamares Corinth transaction routing")


if __name__ == "__main__":
    main()
