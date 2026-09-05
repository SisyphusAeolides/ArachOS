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


def _hardware_command(configuration):
    hardware = configuration.get("hardware", {})
    if not isinstance(hardware, dict):
        raise ValueError("Corinth hardware configuration must be a map")
    executable = configuration.get("executable", "/usr/bin/corinth")
    plan = hardware.get("plan", "/run/arach-installer/hardware-plan.toml")
    catalog_root = hardware.get("catalog-root", "/etc/arach/hwd/catalog")
    if not isinstance(catalog_root, str) or not catalog_root.startswith("/") or any(
        char.isspace() or char == "\x00" for char in catalog_root
    ):
        raise ValueError("Corinth hardware catalog-root must be an absolute path")
    profiles = hardware.get(
        "profiles", catalog_root + "/profiles"
    )
    catalog_lock = hardware.get(
        "catalog-lock", catalog_root + "/catalog.lock"
    )
    keyring = hardware.get("keyring", catalog_root + "/keys.toml")
    recipes = hardware.get("recipes")
    recipes_git = hardware.get("recipes-git")
    work = hardware.get("work", "/var/cache/corinth/work")
    artifacts = hardware.get("artifacts", "/var/cache/corinth/artifacts")
    state = hardware.get("state", "/var/lib/corinth")
    root = hardware.get("root", "/")
    for name, value in (
        ("executable", executable),
        ("plan", plan),
        ("catalog-root", catalog_root),
        ("profiles", profiles),
        ("catalog-lock", catalog_lock),
        ("keyring", keyring),
        ("work", work),
        ("artifacts", artifacts),
        ("state", state),
        ("root", root),
    ):
        if not isinstance(value, str) or not value.startswith("/") or any(
            char.isspace() or char == "\x00" for char in value
        ):
            raise ValueError("Corinth hardware %s must be an absolute path" % name)
    if recipes is not None and recipes_git is not None:
        raise ValueError("Corinth hardware accepts one recipe source at most")
    if recipes is None and recipes_git is None and not profiles and not catalog_lock:
        raise ValueError(
            "Corinth hardware needs recipes or a signed catalog lock"
        )
    command = [
        executable,
        "install",
        "--plan",
        plan,
        "--profiles",
        profiles,
        "--catalog-lock",
        catalog_lock,
        "--keyring",
        keyring,
    ]
    if recipes is not None:
        if not isinstance(recipes, str) or not recipes.startswith("/") or any(
            char.isspace() or char == "\x00" for char in recipes
        ):
            raise ValueError("Corinth hardware recipes must be an absolute path")
        command.extend(("--recipes", recipes))
    elif recipes_git is not None:
        if not isinstance(recipes_git, dict):
            raise ValueError("Corinth hardware recipes-git must be a map")
        url = recipes_git.get("url")
        revision = recipes_git.get("revision")
        if not isinstance(url, str) or not url.startswith("https://") or any(
            char.isspace() or char == "\x00" for char in url
        ):
            raise ValueError("Corinth hardware recipe URL must use HTTPS")
        if not isinstance(revision, str) or not revision or any(
            char not in "0123456789abcdefABCDEF" for char in revision
        ) or len(revision) not in (40, 64):
            raise ValueError("Corinth hardware recipe revision is invalid")
        command.extend(("--recipes-git", url, revision))
    command.extend(
        (
            "--work",
            work,
            "--artifacts",
            artifacts,
            "--state",
            state,
            "--root",
            root,
        )
    )
    if hardware.get("allow-network", False):
        command.append("--allow-network")
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
        hardware = configuration.get("hardware", {})
        if not isinstance(hardware, dict):
            raise ValueError("Corinth hardware configuration must be a map")
        if hardware.get("enabled", False):
            target_env_process_output(_hardware_command(configuration))
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
