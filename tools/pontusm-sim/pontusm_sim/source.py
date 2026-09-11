"""Verify and import data from the known official PontusM source archives.

The public :func:`verify_archive` API authenticates a caller-supplied 2022,
2023, or 2024 outer archive, follows only the recorded nested-archive chain, and parses
the QD version and BIP orbit tables as text data.  It never imports, loads, or
executes anything from an archive.  Samsung source text is not returned or
written into the repository; only immutable parsed facts are exposed.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile
from types import MappingProxyType
from typing import BinaryIO, Mapping
import zipfile

from .types import AlgorithmVersion


MAX_SOURCE_BYTES = 2 * 1024 * 1024
"""Maximum uncompressed size of either requested C source member."""

MAX_ARCHIVE_MEMBER_BYTES = 1024 * 1024 * 1024
"""Maximum uncompressed size of a requested nested archive member."""

MAX_ARCHIVE_MEMBERS = 20_000
"""Maximum number of entries accepted in any opened archive layer."""


class ArchiveVerificationError(ValueError):
    """The supplied archive or parsed source data failed verification."""


@dataclass(frozen=True)
class OrbitBounds:
    """Inclusive horizontal and vertical extrema for an orbit table."""

    min_horizontal: int
    max_horizontal: int
    min_vertical: int
    max_vertical: int


@dataclass(frozen=True)
class SourceVerification:
    """Immutable authenticated facts and orbit data parsed from one release.

    ``archive_hashes`` maps each selected nested member name to its verified
    SHA-256.  ``constants``, ``orbit_tables``, ``orbit_counts``, and
    ``orbit_bounds`` are read-only mappings.  No original source text is kept.
    """

    version: AlgorithmVersion
    outer_sha256: str
    archive_members: tuple[str, ...]
    archive_hashes: Mapping[str, str]
    qd_source_member: str
    qd_source_sha256: str
    orbit_source_member: str
    orbit_source_sha256: str
    constants: Mapping[str, int]
    orbit_tables: Mapping[str, tuple[tuple[int, int], ...]]
    orbit_counts: Mapping[str, int]
    orbit_bounds: Mapping[str, OrbitBounds]
    warnings: tuple[str, ...]

    @property
    def qd_version(self) -> int:
        """Return the verified ``QD_burn_in_ver`` literal."""

        return self.constants["QD_burn_in_ver"]


@dataclass(frozen=True)
class _ArchiveLayer:
    member_suffix: str
    sha256: str


@dataclass(frozen=True)
class _OrbitExpectation:
    name: str
    count: int
    bounds: OrbitBounds


@dataclass(frozen=True)
class _ReleaseSpec:
    outer_sha256: str
    archive_layers: tuple[_ArchiveLayer, ...]
    qd_source_suffix: str
    qd_source_sha256: str
    orbit_source_suffix: str
    orbit_source_sha256: str
    qd_version: int
    orbit_expectations: tuple[_OrbitExpectation, ...]
    warnings: tuple[str, ...]


_STANDARD_BOUNDS = OrbitBounds(-16, 16, -16, 16)

_RELEASE_SPECS: dict[AlgorithmVersion, _ReleaseSpec] = {
    AlgorithmVersion.V18: _ReleaseSpec(
        outer_sha256="057d43ac370eefc4ad4a5d0db9b2c148cb2144c9cc7e8313bcc3cdfda7b5fbb6",
        archive_layers=(
            _ArchiveLayer(
                "22_SmartMonitor_PontusM.zip",
                "15a3f2e1b3466bc3e785005d5d79915b41c2f2a56f6e361d8fe6c6c78b8b4f66",
            ),
            _ArchiveLayer(
                "tztv-media-oscarp_pontusm.zip",
                "8812a3eb27c6016f21b03064a424c0b1a200218e8c0ad663ef87f3355c60fefe",
            ),
        ),
        qd_source_suffix=(
            "tztv-media-sec/sdp_pqe_frc/frc/pontusm/QD_burn_in.c"
        ),
        qd_source_sha256=(
            "81fe83e9b5d0a431a20313994e722c1db7e9438b9935d541c8dae5ddbcbdbb50"
        ),
        orbit_source_suffix=(
            "tztv-media-sec/sdp_pqe_dp/dp/pontusm/bip_orbit_table.h"
        ),
        orbit_source_sha256=(
            "9ce9b88686c3d90f993ad0189548a914032f2ab921a62dde17a1aa96c6a2418b"
        ),
        qd_version=18,
        orbit_expectations=(
            _OrbitExpectation("orbit_table", 1_956, _STANDARD_BOUNDS),
            _OrbitExpectation("orbit_table_ew", 13, _STANDARD_BOUNDS),
        ),
        warnings=(),
    ),
    AlgorithmVersion.V20: _ReleaseSpec(
        outer_sha256="203116537c27d4368dee1e22a7fa5c88a11d727cdda3e024785ce80d4601bee7",
        archive_layers=(
            _ArchiveLayer(
                "23_DTV_PontusML/tztv-media-sec.tgz",
                "3a2a754ba5613be8425dd442bcbb687d3875a7acf0de4322235bcd5953a31ca4",
            ),
        ),
        qd_source_suffix="tztv-media-sec/sdp_pqe_frc/pontusm/QD_burn_in.c",
        qd_source_sha256=(
            "6c2e4f331ee73a203e46b068daef30e1c7c02a7a60184bc82f6a16e1714f37f4"
        ),
        orbit_source_suffix="tztv-media-sec/sdp_pqe_dp/pontusm/bip_orbit_table.c",
        orbit_source_sha256=(
            "4ba52025214749c27fc7475ed6765fcb0cc17b0c779e4e3aa7dd1850476d9b7b"
        ),
        qd_version=20,
        orbit_expectations=(
            _OrbitExpectation("orbit_table", 1_956, _STANDARD_BOUNDS),
            _OrbitExpectation(
                "orbit_table_24x16", 2_980, OrbitBounds(-24, 24, -16, 16)
            ),
            _OrbitExpectation(
                "orbit_table_32x16", 4_102, OrbitBounds(-32, 32, -16, 16)
            ),
            _OrbitExpectation("orbit_table_ew", 13, _STANDARD_BOUNDS),
        ),
        warnings=(
            "orbit_table_24x16 is present in the source but is not selected by "
            "the version-20 runtime model",
        ),
    ),
    AlgorithmVersion.V22: _ReleaseSpec(
        outer_sha256="517d29ac88ad5932871a5f4b4fb3f91bb410aae2af89b62d44a53b4decd0db19",
        archive_layers=(
            _ArchiveLayer(
                "QNxxS95DAFXZA/tztv-media-sec.tgz",
                "1abad655d1627c9b51f68339d38f64a42996ea20da6ab311c5212a67ab547bce",
            ),
        ),
        qd_source_suffix="tztv-media-sec/sdp_pqe_frc/pontusm/QD_burn_in.c",
        qd_source_sha256=(
            "dee42f7fa33a9ae7b5a2f128fc2f34047d01cd3e4e95f1fa4db60a6c0613cf1a"
        ),
        orbit_source_suffix="tztv-media-sec/sdp_pqe_dp/pontusm/bip_orbit_table.c",
        orbit_source_sha256=(
            "4ba52025214749c27fc7475ed6765fcb0cc17b0c779e4e3aa7dd1850476d9b7b"
        ),
        qd_version=22,
        orbit_expectations=(
            _OrbitExpectation("orbit_table", 1_956, _STANDARD_BOUNDS),
            _OrbitExpectation(
                "orbit_table_24x16", 2_980, OrbitBounds(-24, 24, -16, 16)
            ),
            _OrbitExpectation(
                "orbit_table_32x16", 4_102, OrbitBounds(-32, 32, -16, 16)
            ),
            _OrbitExpectation("orbit_table_ew", 13, _STANDARD_BOUNDS),
        ),
        warnings=(
            "the 24Y_SRP generator is not present in the published source; "
            "its 225-cell output remains an explicit runtime input",
            "orbit_table_24x16 is present in the source but is not selected by "
            "the version-22 runtime model",
        ),
    ),
}


_QD_VERSION_RE = re.compile(
    r"\b(?:u32|unsigned\s+int)\s+QD_burn_in_ver\s*=\s*"
    r"(0[xX][0-9A-Fa-f]+|[0-9]+)\s*;"
)
_ORBIT_DECLARATION_RE = re.compile(
    r"^[ \t]*(?:static[ \t]+)?struct[ \t]+ORBIT[ \t]+"
    r"(orbit_table(?:_24x16|_32x16|_ew)?)[ \t]*"
    r"\[[ \t]*\][ \t]*=[ \t]*\{",
    re.MULTILINE,
)
_ORBIT_PAIR_RE = re.compile(r"\{\s*([+-]?[0-9]+)\s*,\s*([+-]?[0-9]+)\s*\}")
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)
_WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:")


def verify_archive(
    path: str | os.PathLike[str], version: AlgorithmVersion | str | int
) -> SourceVerification:
    """Authenticate and parse a supported official PontusM source archive.

    Args:
        path: Path to an unmodified supported official outer ZIP archive.
        version: :class:`AlgorithmVersion`, or the integer/string ``18`` or
            ``20``, or ``22``, identifying the expected release.

    Returns:
        A :class:`SourceVerification` containing immutable parsed constants,
        orbit coordinates, counts, bounds, member names, and hashes.

    Raises:
        ArchiveVerificationError: If any hash, archive structure, member path,
            source initializer, table count, or table bound is unexpected.
        ValueError: If ``version`` is not supported.
    """

    parsed_version = (
        version if isinstance(version, AlgorithmVersion) else AlgorithmVersion.parse(version)
    )
    spec = _RELEASE_SPECS[parsed_version]
    outer_path = Path(path)

    archive_members: list[str] = []
    archive_hashes: dict[str, str] = {}
    try:
        # Pin the outer file once: path replacement must not change the bytes
        # parsed after hashing. ZipFile borrows this stream without closing it.
        with outer_path.open("rb") as outer:
            initial_state = _file_state(outer)
            outer_sha256 = _hash_stream(outer)
            if _file_state(outer) != initial_state:
                raise ArchiveVerificationError("outer archive changed during verification")
            if outer_sha256 != spec.outer_sha256:
                raise ArchiveVerificationError(
                    "outer SHA-256 mismatch: "
                    f"expected {spec.outer_sha256}, got {outer_sha256}"
                )
            outer.seek(0)
            with tempfile.TemporaryDirectory(prefix="pontusm-source-") as temporary:
                current_path: Path | BinaryIO = outer
                current_kind = "zip"
                for index, layer in enumerate(spec.archive_layers):
                    with _ArchiveReader(current_path, current_kind) as archive:
                        selected = archive.find_unique(layer.member_suffix)
                        archive_members.append(selected)
                        destination = Path(temporary) / f"layer-{index}{_archive_extension(layer.member_suffix)}"
                        nested_sha256 = archive.copy_member(
                            selected, destination, MAX_ARCHIVE_MEMBER_BYTES
                        )
                    if nested_sha256 != layer.sha256:
                        raise ArchiveVerificationError(
                            f"nested archive SHA-256 mismatch for {selected}: "
                            f"expected {layer.sha256}, got {nested_sha256}"
                        )
                    archive_hashes[selected] = nested_sha256
                    current_path = destination
                    current_kind = _archive_kind(layer.member_suffix)

                with _ArchiveReader(current_path, current_kind) as archive:
                    qd_member = archive.find_unique(spec.qd_source_suffix)
                    orbit_member = archive.find_unique(spec.orbit_source_suffix)
                    qd_data = archive.read_member(qd_member, MAX_SOURCE_BYTES)
                    orbit_data = archive.read_member(orbit_member, MAX_SOURCE_BYTES)
            final_state = _file_state(outer)
            if final_state != initial_state:
                # Unlinking/replacing the path can change ctime while this open
                # inode remains intact. Rehash that same descriptor to distinguish
                # harmless replacement from an in-place content change.
                if (_hash_stream(outer) != outer_sha256 or _file_state(outer) != final_state):
                    raise ArchiveVerificationError("outer archive changed during verification")
    except OSError as error:
        raise ArchiveVerificationError(f"cannot read archive: {error}") from error

    qd_sha256 = _hash_bytes(qd_data)
    if qd_sha256 != spec.qd_source_sha256:
        raise ArchiveVerificationError(
            "QD source SHA-256 mismatch: "
            f"expected {spec.qd_source_sha256}, got {qd_sha256}"
        )
    orbit_sha256 = _hash_bytes(orbit_data)
    if orbit_sha256 != spec.orbit_source_sha256:
        raise ArchiveVerificationError(
            "orbit source SHA-256 mismatch: "
            f"expected {spec.orbit_source_sha256}, got {orbit_sha256}"
        )

    qd_text = _decode_source(qd_data, qd_member)
    orbit_text = _decode_source(orbit_data, orbit_member)
    qd_version = _parse_qd_version(qd_text)
    if qd_version != spec.qd_version:
        raise ArchiveVerificationError(
            f"QD_burn_in_ver mismatch: expected {spec.qd_version}, got {qd_version}"
        )

    tables = _parse_orbit_tables(orbit_text)
    bounds = _verify_orbit_tables(tables, spec.orbit_expectations)
    counts = {name: len(points) for name, points in tables.items()}

    return SourceVerification(
        version=parsed_version,
        outer_sha256=outer_sha256,
        archive_members=tuple(archive_members),
        archive_hashes=MappingProxyType(dict(archive_hashes)),
        qd_source_member=qd_member,
        qd_source_sha256=qd_sha256,
        orbit_source_member=orbit_member,
        orbit_source_sha256=orbit_sha256,
        constants=MappingProxyType({"QD_burn_in_ver": qd_version}),
        orbit_tables=MappingProxyType(dict(tables)),
        orbit_counts=MappingProxyType(counts),
        orbit_bounds=MappingProxyType(bounds),
        warnings=spec.warnings,
    )


verify_source_archive = verify_archive
"""Descriptive alias for :func:`verify_archive`."""


def _file_state(stream: BinaryIO) -> tuple[int, ...]:
    status = os.fstat(stream.fileno())
    return (status.st_dev, status.st_ino, status.st_size,
            status.st_mtime_ns, status.st_ctime_ns)


def _hash_stream(stream: BinaryIO) -> str:
    stream.seek(0)
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def _hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _archive_extension(member_name: str) -> str:
    lower = member_name.lower()
    for extension in (".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".zip", ".tar"):
        if lower.endswith(extension):
            return extension
    return ".archive"


def _archive_kind(member_name: str) -> str:
    lower = member_name.lower()
    if lower.endswith(".zip"):
        return "zip"
    if lower.endswith((".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".tar")):
        return "tar"
    raise ArchiveVerificationError(
        f"unsupported archive type for nested member {member_name!r}"
    )


def _safe_member_name(name: str) -> None:
    trimmed = name[:-1] if name.endswith("/") else name
    parts = trimmed.split("/")
    if (
        not trimmed
        or "\x00" in name
        or "\\" in name
        or name.startswith("/")
        or _WINDOWS_DRIVE_RE.match(name)
        or any(part in ("", ".", "..") for part in parts)
        or PurePosixPath(trimmed).is_absolute()
    ):
        raise ArchiveVerificationError(f"unsafe member path: {name!r}")


class _ArchiveReader:
    """Metadata-validating ZIP/TAR reader for selected member data only."""

    def __init__(self, path: Path | BinaryIO, kind: str) -> None:
        self._path = path
        self._kind = kind
        self._archive: zipfile.ZipFile | tarfile.TarFile | None = None
        self._members: dict[str, zipfile.ZipInfo | tarfile.TarInfo] = {}

    def __enter__(self) -> "_ArchiveReader":
        try:
            if self._kind == "zip":
                archive: zipfile.ZipFile | tarfile.TarFile = zipfile.ZipFile(
                    self._path, "r"
                )
                members: list[zipfile.ZipInfo | tarfile.TarInfo] = archive.infolist()
            elif self._kind == "tar":
                archive = (tarfile.open(self._path, mode="r:*") if isinstance(self._path, Path)
                           else tarfile.open(fileobj=self._path, mode="r:*"))
                members = archive.getmembers()
            else:
                raise ArchiveVerificationError(
                    f"unsupported archive type {self._kind!r}"
                )
        except (OSError, tarfile.TarError, zipfile.BadZipFile) as error:
            raise ArchiveVerificationError(
                f"cannot parse {self._kind} archive {self._path.name!r}: {error}"
            ) from error

        self._archive = archive
        try:
            self._validate_members(members)
        except Exception:
            archive.close()
            self._archive = None
            raise
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if self._archive is not None:
            self._archive.close()

    def _validate_members(
        self, members: list[zipfile.ZipInfo | tarfile.TarInfo]
    ) -> None:
        if len(members) > MAX_ARCHIVE_MEMBERS:
            raise ArchiveVerificationError(
                f"archive has {len(members)} members; limit is {MAX_ARCHIVE_MEMBERS}"
            )
        for member in members:
            name = member.filename if isinstance(member, zipfile.ZipInfo) else member.name
            _safe_member_name(name)
            if name in self._members:
                raise ArchiveVerificationError(
                    f"archive contains duplicate member name {name!r}"
                )

            if isinstance(member, zipfile.ZipInfo):
                mode = (member.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(mode):
                    raise ArchiveVerificationError(f"archive contains link member {name!r}")
                file_type = stat.S_IFMT(mode)
                if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ArchiveVerificationError(
                        f"archive contains unsupported special member {name!r}"
                    )
                if member.flag_bits & 0x1:
                    raise ArchiveVerificationError(
                        f"archive contains encrypted member {name!r}"
                    )
            else:
                if member.issym() or member.islnk():
                    raise ArchiveVerificationError(f"archive contains link member {name!r}")
                if not (member.isfile() or member.isdir()):
                    raise ArchiveVerificationError(
                        f"archive contains unsupported special member {name!r}"
                    )
            self._members[name] = member

    def find_unique(self, suffix: str) -> str:
        normalized = suffix.strip("/")
        matches = [
            name
            for name in self._members
            if name == normalized or name.endswith("/" + normalized)
        ]
        if not matches:
            raise ArchiveVerificationError(
                f"missing required member matching suffix {suffix!r}"
            )
        if len(matches) != 1:
            raise ArchiveVerificationError(
                f"ambiguous required member suffix {suffix!r}: {matches!r}"
            )
        return matches[0]

    def _regular_member(
        self, name: str, size_limit: int
    ) -> zipfile.ZipInfo | tarfile.TarInfo:
        member = self._members[name]
        is_file = (
            not member.is_dir()
            if isinstance(member, zipfile.ZipInfo)
            else member.isfile()
        )
        if not is_file:
            raise ArchiveVerificationError(f"required member is not a file: {name!r}")
        size = member.file_size if isinstance(member, zipfile.ZipInfo) else member.size
        if size > size_limit:
            raise ArchiveVerificationError(
                f"required member {name!r} exceeds the {size_limit}-byte limit"
            )
        return member

    def _open_member(
        self, member: zipfile.ZipInfo | tarfile.TarInfo
    ) -> BinaryIO:
        assert self._archive is not None
        if isinstance(self._archive, zipfile.ZipFile):
            assert isinstance(member, zipfile.ZipInfo)
            return self._archive.open(member, "r")
        assert isinstance(self._archive, tarfile.TarFile)
        assert isinstance(member, tarfile.TarInfo)
        stream = self._archive.extractfile(member)
        if stream is None:
            raise ArchiveVerificationError(
                f"cannot read required member {member.name!r}"
            )
        return stream

    def read_member(self, name: str, size_limit: int) -> bytes:
        member = self._regular_member(name, size_limit)
        with self._open_member(member) as source:
            data = source.read(size_limit + 1)
        if len(data) > size_limit:
            raise ArchiveVerificationError(
                f"required member {name!r} exceeds the {size_limit}-byte limit"
            )
        return data

    def copy_member(self, name: str, destination: Path, size_limit: int) -> str:
        member = self._regular_member(name, size_limit)
        digest = hashlib.sha256()
        written = 0
        with self._open_member(member) as source, destination.open("xb") as output:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > size_limit:
                    raise ArchiveVerificationError(
                        f"required member {name!r} exceeds the {size_limit}-byte limit"
                    )
                digest.update(chunk)
                output.write(chunk)
        return digest.hexdigest()


def _decode_source(data: bytes, member: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ArchiveVerificationError(
            f"source member {member!r} is not valid UTF-8"
        ) from error


def _parse_qd_version(source: str) -> int:
    matches = _QD_VERSION_RE.findall(source)
    if len(matches) != 1:
        raise ArchiveVerificationError(
            "expected exactly one literal QD_burn_in_ver initializer"
        )
    return int(matches[0], 0)


def _parse_orbit_tables(source: str) -> dict[str, tuple[tuple[int, int], ...]]:
    tables: dict[str, tuple[tuple[int, int], ...]] = {}
    declarations = list(_ORBIT_DECLARATION_RE.finditer(source))
    for declaration in declarations:
        name = declaration.group(1)
        if name in tables:
            raise ArchiveVerificationError(f"duplicate orbit table {name!r}")
        terminator = re.search(r"\}\s*;", source[declaration.end() :])
        if terminator is None:
            raise ArchiveVerificationError(f"unterminated initializer for {name}")
        body = source[
            declaration.end() : declaration.end() + terminator.start()
        ]
        without_comments = _COMMENT_RE.sub("", body)
        points = tuple(
            (int(match.group(1)), int(match.group(2)))
            for match in _ORBIT_PAIR_RE.finditer(without_comments)
        )
        remainder = _ORBIT_PAIR_RE.sub("", without_comments)
        if re.search(r"[^\s,]", remainder):
            raise ArchiveVerificationError(f"malformed initializer for {name}")
        tables[name] = points
    return tables


def _verify_orbit_tables(
    tables: Mapping[str, tuple[tuple[int, int], ...]],
    expectations: tuple[_OrbitExpectation, ...],
) -> dict[str, OrbitBounds]:
    expected_names = {expectation.name for expectation in expectations}
    actual_names = set(tables)
    if missing := sorted(expected_names - actual_names):
        raise ArchiveVerificationError(f"missing orbit tables: {', '.join(missing)}")
    if unexpected := sorted(actual_names - expected_names):
        raise ArchiveVerificationError(
            f"unexpected orbit tables: {', '.join(unexpected)}"
        )

    bounds: dict[str, OrbitBounds] = {}
    for expectation in expectations:
        points = tables[expectation.name]
        if len(points) != expectation.count:
            raise ArchiveVerificationError(
                f"orbit table {expectation.name} has {len(points)} entries; "
                f"expected {expectation.count}"
            )
        if not points:
            raise ArchiveVerificationError(
                f"orbit table {expectation.name} must not be empty"
            )
        actual_bounds = OrbitBounds(
            min(point[0] for point in points),
            max(point[0] for point in points),
            min(point[1] for point in points),
            max(point[1] for point in points),
        )
        if actual_bounds != expectation.bounds:
            raise ArchiveVerificationError(
                f"orbit table {expectation.name} bounds are {actual_bounds}; "
                f"expected {expectation.bounds}"
            )
        bounds[expectation.name] = actual_bounds
    return bounds
