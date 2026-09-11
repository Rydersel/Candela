import hashlib
import io
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

import pontusm_sim.source as source
from pontusm_sim.source import ArchiveVerificationError, OrbitBounds, verify_archive
from pontusm_sim.types import AlgorithmVersion


QD_MEMBER = "tztv-media-sec/sdp_pqe_frc/pontusm/QD_burn_in.c"
ORBIT_MEMBER = "tztv-media-sec/sdp_pqe_dp/pontusm/bip_orbit_table.c"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _zip_bytes(members: dict[str, bytes], *, symlink: str | None = None) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in members.items():
            archive.writestr(name, data)
        if symlink is not None:
            info = zipfile.ZipInfo(symlink)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b"target")
    return output.getvalue()


def _tar_bytes(members: dict[str, bytes], *, symlink: str | None = None) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        if symlink is not None:
            info = tarfile.TarInfo(symlink)
            info.type = tarfile.SYMTYPE
            info.linkname = "target"
            archive.addfile(info)
    return output.getvalue()


class FixtureArchive:
    def __init__(
        self,
        directory: Path,
        *,
        qd_source: bytes | None = None,
        orbit_source: bytes | None = None,
        extra_media_members: dict[str, bytes] | None = None,
        media_symlink: str | None = None,
        outer_extra_members: dict[str, bytes] | None = None,
        outer_symlink: str | None = None,
        media_member: str = "release/tztv-media-sec.tgz",
    ) -> None:
        self.qd_source = qd_source or (
            b"void QD_burn_in(void) {\n"
            b"    u32 QD_burn_in_ver = 20;\n"
            b"}\n"
        )
        self.orbit_source = orbit_source or (
            b"static struct ORBIT orbit_table[] = {\n"
            b"    { 0, 0 }, { 1, -1 },\n"
            b"};\n"
            b"static struct ORBIT orbit_table_ew[] = {\n"
            b"    { -2, 2 },\n"
            b"};\n"
        )
        media_members = {
            QD_MEMBER: self.qd_source,
            ORBIT_MEMBER: self.orbit_source,
        }
        media_members.update(extra_media_members or {})
        self.media = _tar_bytes(media_members, symlink=media_symlink)
        outer_members = {media_member: self.media}
        outer_members.update(outer_extra_members or {})
        outer = _zip_bytes(outer_members, symlink=outer_symlink)
        self.path = directory / "fixture.zip"
        self.path.write_bytes(outer)
        self.spec = source._ReleaseSpec(
            outer_sha256=_sha256(outer),
            archive_layers=(
                source._ArchiveLayer(
                    member_suffix="tztv-media-sec.tgz",
                    sha256=_sha256(self.media),
                ),
            ),
            qd_source_suffix=QD_MEMBER,
            qd_source_sha256=_sha256(self.qd_source),
            orbit_source_suffix=ORBIT_MEMBER,
            orbit_source_sha256=_sha256(self.orbit_source),
            qd_version=20,
            orbit_expectations=(
                source._OrbitExpectation("orbit_table", 2, OrbitBounds(0, 1, -1, 0)),
                source._OrbitExpectation("orbit_table_ew", 1, OrbitBounds(-2, -2, 2, 2)),
            ),
            warnings=(),
        )


class SourceArchiveTests(unittest.TestCase):
    def _verify(self, fixture: FixtureArchive):
        with mock.patch.dict(
            source._RELEASE_SPECS,
            {AlgorithmVersion.V20: fixture.spec},
            clear=False,
        ):
            return verify_archive(fixture.path, AlgorithmVersion.V20)

    def test_verified_nested_archive_exposes_constants_and_immutable_orbits(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(Path(directory))
            result = self._verify(fixture)

        self.assertEqual(result.version, AlgorithmVersion.V20)
        self.assertEqual(result.constants["QD_burn_in_ver"], 20)
        self.assertEqual(result.archive_members, ("release/tztv-media-sec.tgz",))
        self.assertEqual(result.qd_source_member, QD_MEMBER)
        self.assertEqual(result.orbit_source_member, ORBIT_MEMBER)
        self.assertEqual(result.orbit_tables["orbit_table"], ((0, 0), (1, -1)))
        self.assertEqual(
            result.orbit_bounds["orbit_table"], OrbitBounds(0, 1, -1, 0)
        )
        with self.assertRaises(TypeError):
            result.constants["QD_burn_in_ver"] = 99
        with self.assertRaises(TypeError):
            result.orbit_tables["orbit_table"] = ()

    def test_rejects_unaccepted_outer_hash_before_archive_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wrong.zip"
            path.write_bytes(b"not even a zip")
            with self.assertRaisesRegex(ArchiveVerificationError, "outer SHA-256"):
                verify_archive(path, AlgorithmVersion.V20)

    def test_outer_path_replacement_after_hashing_keeps_the_original_open_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(Path(directory))
            replacement = Path(directory, "replacement.zip")
            replacement.write_bytes(b"different bytes, not an archive")
            original_enter = source._ArchiveReader.__enter__
            replaced = False

            def replace_before_parse(reader):
                nonlocal replaced
                if not replaced:
                    replaced = True
                    replacement.replace(fixture.path)
                return original_enter(reader)

            with mock.patch.object(source._ArchiveReader, "__enter__", replace_before_parse):
                result = self._verify(fixture)
            self.assertEqual(fixture.path.read_bytes(), b"different bytes, not an archive")
            self.assertEqual(result.outer_sha256, fixture.spec.outer_sha256)
            self.assertEqual(result.orbit_tables["orbit_table"], ((0, 0), (1, -1)))
            self.assertEqual(result.qd_version, 20)

    def test_outer_in_place_mutation_during_parsing_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(Path(directory))
            original_enter = source._ArchiveReader.__enter__
            changed = False

            def mutate_before_parse(reader):
                nonlocal changed
                if not changed:
                    changed = True
                    with fixture.path.open("ab") as stream:
                        stream.write(b"appended after the verified hash")
                return original_enter(reader)

            with mock.patch.object(source._ArchiveReader, "__enter__", mutate_before_parse):
                with self.assertRaisesRegex(ArchiveVerificationError, "changed during verification"):
                    self._verify(fixture)

    def test_rejects_traversal_in_every_opened_archive_layer(self):
        cases = (
            {"outer_extra_members": {"../escape": b"x"}},
            {"extra_media_members": {"nested/../../escape": b"x"}},
        )
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                fixture = FixtureArchive(Path(directory), **options)
                with self.assertRaisesRegex(ArchiveVerificationError, "unsafe member path"):
                    self._verify(fixture)

    def test_rejects_links_in_zip_or_tar_layers(self):
        cases = (
            {"outer_symlink": "release/link"},
            {"media_symlink": "tztv-media-sec/link"},
        )
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                fixture = FixtureArchive(Path(directory), **options)
                with self.assertRaisesRegex(ArchiveVerificationError, "link member"):
                    self._verify(fixture)

    def test_rejects_oversized_requested_source_without_reading_it(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(
                Path(directory), qd_source=b"x" * (source.MAX_SOURCE_BYTES + 1)
            )
            with self.assertRaisesRegex(ArchiveVerificationError, "exceeds.*limit"):
                self._verify(fixture)

    def test_does_not_read_unrequested_large_regular_members(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(
                Path(directory),
                extra_media_members={
                    "tztv-media-sec/unrelated.bin": b"x"
                    * (source.MAX_SOURCE_BYTES + 1)
                },
            )
            result = self._verify(fixture)
        self.assertEqual(result.constants["QD_burn_in_ver"], 20)

    def test_rejects_missing_or_ambiguous_required_suffixes(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(
                Path(directory), media_member="release/not-media.tgz"
            )
            with self.assertRaisesRegex(ArchiveVerificationError, "missing.*media-sec"):
                self._verify(fixture)

        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(
                Path(directory),
                outer_extra_members={"copy/tztv-media-sec.tgz": b"other"},
            )
            with self.assertRaisesRegex(ArchiveVerificationError, "ambiguous.*media-sec"):
                self._verify(fixture)

    def test_rejects_source_hash_mismatch_and_malformed_orbit_initializer(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(Path(directory))
            fixture.spec = source._ReleaseSpec(
                **{
                    **fixture.spec.__dict__,
                    "qd_source_sha256": "0" * 64,
                }
            )
            with self.assertRaisesRegex(ArchiveVerificationError, "QD source SHA-256"):
                self._verify(fixture)

        with tempfile.TemporaryDirectory() as directory:
            fixture = FixtureArchive(
                Path(directory),
                orbit_source=(
                    b"struct ORBIT orbit_table[] = {{ 0, value }};\n"
                    b"struct ORBIT orbit_table_ew[] = {{ -2, 2 }};\n"
                ),
            )
            fixture.spec = source._ReleaseSpec(
                **{
                    **fixture.spec.__dict__,
                    "orbit_expectations": (
                        source._OrbitExpectation(
                            "orbit_table", 1, OrbitBounds(0, 0, 0, 0)
                        ),
                        source._OrbitExpectation(
                            "orbit_table_ew", 1, OrbitBounds(-2, -2, 2, 2)
                        ),
                    ),
                }
            )
            with self.assertRaisesRegex(ArchiveVerificationError, "malformed.*orbit_table"):
                self._verify(fixture)

    def test_rejects_unsupported_nested_archive_type(self):
        with tempfile.TemporaryDirectory() as directory:
            media = b"not an archive"
            outer = _zip_bytes({"release/tztv-media-sec.rar": media})
            path = Path(directory) / "fixture.zip"
            path.write_bytes(outer)
            spec = source._ReleaseSpec(
                outer_sha256=_sha256(outer),
                archive_layers=(
                    source._ArchiveLayer(
                        member_suffix="tztv-media-sec.rar",
                        sha256=_sha256(media),
                    ),
                ),
                qd_source_suffix=QD_MEMBER,
                qd_source_sha256="0" * 64,
                orbit_source_suffix=ORBIT_MEMBER,
                orbit_source_sha256="0" * 64,
                qd_version=20,
                orbit_expectations=(),
                warnings=(),
            )
            with mock.patch.dict(
                source._RELEASE_SPECS, {AlgorithmVersion.V20: spec}, clear=False
            ):
                with self.assertRaisesRegex(ArchiveVerificationError, "unsupported archive"):
                    verify_archive(path, AlgorithmVersion.V20)


class OfficialArchiveIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path_2022 = os.environ.get("PONTUSM_2022_ARCHIVE")
        cls.path_2023 = os.environ.get("PONTUSM_2023_ARCHIVE")
        cls.path_2024 = os.environ.get("PONTUSM_2024_ARCHIVE")
        cls.source_2022 = (
            verify_archive(cls.path_2022, AlgorithmVersion.V18)
            if cls.path_2022
            else None
        )
        cls.source_2023 = (
            verify_archive(cls.path_2023, AlgorithmVersion.V20)
            if cls.path_2023
            else None
        )
        cls.source_2024 = (
            verify_archive(cls.path_2024, AlgorithmVersion.V22)
            if cls.path_2024
            else None
        )

    def test_2022_official_archive(self):
        if self.source_2022 is None:
            self.skipTest("PONTUSM_2022_ARCHIVE is not set")
        result = self.source_2022
        self.assertEqual(result.qd_source_sha256, "81fe83e9b5d0a431a20313994e722c1db7e9438b9935d541c8dae5ddbcbdbb50")
        self.assertEqual(result.constants["QD_burn_in_ver"], 18)
        self.assertEqual(len(result.orbit_tables["orbit_table"]), 1956)
        self.assertEqual(len(result.orbit_tables["orbit_table_ew"]), 13)

    def test_2023_official_archive(self):
        if self.source_2023 is None:
            self.skipTest("PONTUSM_2023_ARCHIVE is not set")
        result = self.source_2023
        self.assertEqual(result.qd_source_sha256, "6c2e4f331ee73a203e46b068daef30e1c7c02a7a60184bc82f6a16e1714f37f4")
        self.assertEqual(result.constants["QD_burn_in_ver"], 20)
        self.assertEqual(len(result.orbit_tables["orbit_table"]), 1956)
        self.assertEqual(len(result.orbit_tables["orbit_table_24x16"]), 2980)
        self.assertEqual(len(result.orbit_tables["orbit_table_32x16"]), 4102)
        self.assertEqual(len(result.orbit_tables["orbit_table_ew"]), 13)

    def test_2024_official_archive(self):
        if self.source_2024 is None:
            self.skipTest("PONTUSM_2024_ARCHIVE is not set")
        result = self.source_2024
        self.assertEqual(
            result.qd_source_sha256,
            "dee42f7fa33a9ae7b5a2f128fc2f34047d01cd3e4e95f1fa4db60a6c0613cf1a",
        )
        self.assertEqual(result.constants["QD_burn_in_ver"], 22)
        self.assertEqual(len(result.orbit_tables["orbit_table"]), 1956)
        self.assertEqual(len(result.orbit_tables["orbit_table_24x16"]), 2980)
        self.assertEqual(len(result.orbit_tables["orbit_table_32x16"]), 4102)
        self.assertEqual(len(result.orbit_tables["orbit_table_ew"]), 13)

    def test_official_normal_orbit_is_identical_across_releases(self):
        if self.source_2022 is None or self.source_2023 is None:
            self.skipTest("both PONTUSM archive paths are required")
        self.assertEqual(
            self.source_2022.orbit_tables["orbit_table"],
            self.source_2023.orbit_tables["orbit_table"],
        )

    def test_2024_orbits_are_identical_to_2023(self):
        if self.source_2023 is None or self.source_2024 is None:
            self.skipTest("both 2023 and 2024 PontusM archive paths are required")
        self.assertEqual(self.source_2023.orbit_tables, self.source_2024.orbit_tables)


if __name__ == "__main__":
    unittest.main()
