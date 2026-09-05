#!/usr/bin/env python3
"""Install Calamares selections through the signed Corinth service."""

import subprocess
from string import Template

import libcalamares
from libcalamares.utils import target_env_process_output


_INSTALL = "install"
_REMOVE = "remove"


def pretty_name():
    return "Install ArachOS packages."


def _config():
    value = libcalamares.job.configuration.get("corinth", {})
    if not isinstance(value, dict):
        raise ValueError("the Corinth Calamares configuration must be a map")
    return value


def _package_name(value):
    if not isinstance(value, str):
        raise ValueError("a package entry must be a string or a package map")
    if not value or len(value) > 255:
        raise ValueError("a package name is empty or too long")
    if value.startswith("-") or "/" in value or any(char.isspace() for char in value):
        raise ValueError("a package name contains an unsafe character")
    if "\x00" in value:
        raise ValueError("a package name contains a NUL byte")
    return value


def _package_data(value):
    if isinstance(value, str):
        return _package_name(value)
    if not isinstance(value, dict) or "package" not in value:
        raise ValueError("a package map must contain package")
    package = _package_name(value["package"])
    before = value.get("pre-script")
    after = value.get("post-script")
    for script in (before, after):
        if script is not None and not isinstance(script, str):
            raise ValueError("package scripts must be strings")
    if before or after:
        raise ValueError(
            "package scripts are disabled; use a signed Corinth recipe instead"
        )
    return package


def _command(configuration, verb, package):
    executable = configuration.get("executable", "/usr/bin/corinth")
    service_config = configuration.get("service-config", "/etc/corinth/service.toml")
    service_signature = configuration.get(
        "service-signature", "/etc/corinth/service.toml.sig"
    )
    keyring = configuration.get("keyring", "/etc/arach/hwd/keys.toml")
    for name, value in (
        ("executable", executable),
        ("service-config", service_config),
        ("service-signature", service_signature),
        ("keyring", keyring),
    ):
        if not isinstance(value, str) or not value.startswith("/") or any(
            char.isspace() for char in value
        ):
            raise ValueError("Corinth %s must be an absolute path" % name)
    command = [
        executable,
        verb,
        package,
        "--config",
        service_config,
        "--config-signature",
        service_signature,
        "--keyring",
        keyring,
    ]
    if configuration.get("offline", False):
        command.append("--offline")
    return command


def _selected_operations():
    operations = list(libcalamares.job.configuration.get("operations", []))
    if libcalamares.globalstorage.contains("packageOperations"):
        operations.extend(libcalamares.globalstorage.value("packageOperations"))
    if not all(isinstance(entry, dict) for entry in operations):
        raise ValueError("Corinth package operations must be maps")
    return operations


def _packages_in(operations):
    count = 0
    for entry in operations:
        for action, values in entry.items():
            if action == "source":
                continue
            if action not in ("install", "try_install", "remove", "try_remove", "localInstall"):
                raise ValueError("unknown package operation: %s" % action)
            if not isinstance(values, list):
                raise ValueError("package operation %s must contain a list" % action)
            count += len(values)
    return count


def _localized(value):
    package = _package_data(value)
    locale = libcalamares.globalstorage.value("locale") or "en"
    if locale == "en" and "LOCALE" in package:
        return None
    if locale != "en":
        package = Template(package).safe_substitute(LOCALE=locale)
    return _package_name(package)


def _run_package(configuration, verb, value):
    package = _localized(value)
    if package is None:
        return
    target_env_process_output(_command(configuration, verb, package))


def _run_entry(configuration, entry, done, total):
    for action, values in entry.items():
        if action == "source":
            libcalamares.utils.debug("Corinth package list from %s" % values)
            continue
        if action == "localInstall":
            raise ValueError("Corinth does not accept unverified local package files")
        verb = _INSTALL if action in ("install", "try_install") else _REMOVE
        optional = action in ("try_install", "try_remove")
        for value in values:
            try:
                _run_package(configuration, verb, value)
            except subprocess.CalledProcessError as error:
                if not optional:
                    raise
                libcalamares.utils.warning(
                    "Corinth could not process optional package %s: %s" % (value, error)
                )
            done += 1
            libcalamares.job.setprogress(done / total if total else 1.0)
    return done


def run():
    try:
        configuration = _config()
        if configuration.get("update-system", False):
            return (
                "Corinth configuration error",
                "The installer accepts explicit package selections only; broad system updates are not run.",
            )
        operations = _selected_operations()
        total = _packages_in(operations)
        done = 0
        for entry in operations:
            done = _run_entry(configuration, entry, done, total)
        libcalamares.job.setprogress(1.0)
        return None
    except (ValueError, KeyError) as error:
        return "Corinth configuration error", str(error)
    except subprocess.CalledProcessError as error:
        return (
            "Corinth package transaction failed",
            "The signed Corinth transaction returned exit status %s." % error.returncode,
        )
    except OSError as error:
        return "Corinth package transaction failed", str(error)
