"""Atomic, no-replace publication for complete artifact directories."""

from __future__ import annotations

import ctypes
import errno
import os
from pathlib import Path
import sys
import tempfile
from typing import Callable, Mapping


def _publish(staging: Path, destination: Path) -> None:
    """Atomically rename a complete sibling directory without replacing a path."""
    source_name, target_name = str(staging), str(destination)
    if "\0" in source_name or "\0" in target_name:
        raise ValueError("publication paths must not contain NUL")
    unavailable = "atomic no-replace directory publication unavailable on this platform"
    try:
        if sys.platform == "win32":
            native = ctypes.WinDLL("kernel32", use_last_error=True).MoveFileExW
            native.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
            native.restype = ctypes.c_int
            arguments = (source_name, target_name, 0)
        elif sys.platform in ("darwin", "linux"):
            library = ctypes.CDLL(None, use_errno=True)
            if sys.platform == "darwin":
                native = library.renamex_np
                native.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
                arguments = (
                    os.fsencode(staging),
                    os.fsencode(destination),
                    0x00000004,  # RENAME_EXCL
                )
            else:
                native = library.renameat2
                native.argtypes = [
                    ctypes.c_int,
                    ctypes.c_char_p,
                    ctypes.c_int,
                    ctypes.c_char_p,
                    ctypes.c_uint,
                ]
                arguments = (
                    -100,  # AT_FDCWD
                    os.fsencode(staging),
                    -100,
                    os.fsencode(destination),
                    1,  # RENAME_NOREPLACE
                )
            native.restype = ctypes.c_int
        else:
            raise OSError(errno.ENOTSUP, unavailable)
    except (AttributeError, OSError) as error:
        raise OSError(errno.ENOTSUP, unavailable) from error

    result = native(*arguments)
    if sys.platform == "win32":
        if result:
            return
        code = ctypes.get_last_error()
        if code in (80, 183):
            raise ValueError(f"output destination already exists: {destination}")
        raise ctypes.WinError(code)
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            raise ValueError(f"output destination already exists: {destination}")
        raise OSError(
            code,
            f"atomic no-replace directory publication failed: {os.strerror(code)}",
            target_name,
        )


def publish_tree(
    output_directory: str | os.PathLike[str],
    render: Callable[[Path], None],
) -> None:
    """Render under a private sibling and atomically publish the complete tree."""
    destination = Path(output_directory).absolute()
    if os.path.lexists(destination):
        raise ValueError(f"output destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        dir=destination.parent, prefix=f".{destination.name}.staging-"
    ) as temporary:
        staging = Path(temporary, "result")
        render(staging)
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError("artifact renderer did not create a regular directory")
        _publish(staging, destination)


def publish_files(
    contents: Mapping[str, bytes], output_directory: str | os.PathLike[str]
) -> None:
    """Atomically publish a flat mapping of artifact names to rendered bytes."""
    validated: dict[str, bytes] = {}
    for name, raw in contents.items():
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or name in (".", "..")
        ):
            raise ValueError("artifact names must be simple relative file names")
        if not isinstance(raw, bytes):
            raise TypeError("artifact contents must be bytes")
        validated[name] = raw

    def render(staging: Path) -> None:
        staging.mkdir()
        for name, raw in validated.items():
            (staging / name).write_bytes(raw)

    publish_tree(output_directory, render)
