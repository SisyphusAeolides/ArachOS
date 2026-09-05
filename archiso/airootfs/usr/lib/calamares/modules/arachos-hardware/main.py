#!/usr/bin/env python3
"""Resolve the target hardware through the signed Arach-HWD catalog."""

import subprocess

import libcalamares
from libcalamares.utils import target_env_process_output


_DEFAULT_CATALOG = "/etc/arach/hwd/catalog"
_DEFAULT_RUNTIME_CATALOG = "/run/arach-installer/catalog"
_DEFAULT_OUTPUT = "/run/arach-installer/hardware-plan.toml"


def pretty_name():
    return "Preparing Arach hardware."


def _configuration():
    value = libcalamares.job.configuration
    if not isinstance(value, dict):
        raise ValueError("the Arach hardware configuration must be a map")
    return value


def _path(configuration, name, default=None):
    value = configuration.get(name, default)
    if not isinstance(value, str) or not value.startswith("/") or any(
        char.isspace() or char == "\x00" for char in value
    ):
        raise ValueError("Arach hardware %s must be an absolute path" % name)
    return value


def _path_list(configuration, name):
    value = configuration.get(name, [])
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        raise ValueError("Arach hardware %s must be a list of paths" % name)
    return [_path({name: item}, name) for item in value]


def _catalog_sync(configuration):
    sync = configuration.get("catalog-sync")
    if sync is None:
        return None
    if not isinstance(sync, dict):
        raise ValueError("Arach hardware catalog-sync must be a map")
    executable = _path(sync, "executable", "/usr/bin/arach-hwd-catalog-sync")
    manifest = sync.get("manifest-url")
    signature = sync.get("signature-url")
    if not isinstance(manifest, str) or not manifest.startswith("https://"):
        raise ValueError("Arach hardware manifest-url must use HTTPS")
    if not isinstance(signature, str) or not signature.startswith("https://"):
        raise ValueError("Arach hardware signature-url must use HTTPS")
    if any(char.isspace() or char == "\x00" for char in manifest + signature):
        raise ValueError("Arach hardware catalog URLs contain unsafe characters")
    keyring = _path(sync, "keyring", "/etc/arach/hwd/keys.toml")
    output = _path(sync, "output", _DEFAULT_RUNTIME_CATALOG)
    return [
        executable,
        "--manifest-url",
        manifest,
        "--signature-url",
        signature,
        "--keyring",
        keyring,
        "--output",
        output,
    ]


def _plan_command(configuration):
    executable = _path(configuration, "executable", "/usr/bin/arach-hwd")
    sync = configuration.get("catalog-sync")
    catalog_root = _path(configuration, "catalog-root", _DEFAULT_CATALOG)
    if isinstance(sync, dict):
        catalog_root = _path(sync, "output", _DEFAULT_RUNTIME_CATALOG)
    profiles = _path(configuration, "profiles", catalog_root + "/profiles")
    keyring = _path(configuration, "keyring", catalog_root + "/keys.toml")
    catalog_lock = _path(
        configuration, "catalog-lock", catalog_root + "/catalog.lock"
    )
    output = _path(configuration, "output", _DEFAULT_OUTPUT)
    sysfs = _path(configuration, "sysfs", "/sys")
    driver_abi = configuration.get("driver-abi", "1.0")
    if not isinstance(driver_abi, str) or not driver_abi or any(
        char.isspace() or char == "\x00" for char in driver_abi
    ):
        raise ValueError("Arach hardware driver-abi is invalid")
    command = [
        executable,
        "plan",
        "--sysfs",
        sysfs,
        "--profiles",
        profiles,
        "--keyring",
        keyring,
        "--catalog-lock",
        catalog_lock,
        "--driver-abi",
        driver_abi,
        "--output",
        output,
    ]
    for option in (
        "modules-alias",
        "modules-firmware",
        "modules-dep",
        "modules-builtin",
    ):
        for path in _path_list(configuration, option):
            command.extend(("--" + option, path))
    for path in _path_list(configuration, "firmware-root"):
        command.extend(("--firmware-root", path))
    if configuration.get("require-target-profiles", True):
        command.append("--require-target-profiles")
    return command


def _prepare_output_parent(output):
    parent = output.rsplit("/", 1)[0] or "/"
    return ["/usr/bin/mkdir", "-p", parent]


def run():
    try:
        configuration = _configuration()
        if not configuration.get("enabled", True):
            libcalamares.job.setprogress(1.0)
            return None
        target_env_process_output(_prepare_output_parent(_path(configuration, "output", _DEFAULT_OUTPUT)))
        sync_command = _catalog_sync(configuration)
        if sync_command is not None:
            target_env_process_output(sync_command)
        target_env_process_output(_plan_command(configuration))
        libcalamares.job.setprogress(1.0)
        return None
    except (ValueError, KeyError) as error:
        return "Arach hardware configuration error", str(error)
    except subprocess.CalledProcessError as error:
        return (
            "Arach hardware planning failed",
            "The signed Arach-HWD target plan returned exit status %s."
            % error.returncode,
        )
    except OSError as error:
        return "Arach hardware planning failed", str(error)
