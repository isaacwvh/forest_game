"""Portable checks of the approved cosmetic package; no gameplay catalogue changes."""
from pathlib import Path
import hashlib
import json
import struct
import zipfile


def validate_garden_environment(repo: Path, project_text: str):
    folder = repo / 'assets/garden-environment/v1'
    manifest = json.loads((folder / 'environment.json').read_text(encoding='utf-8'))
    assert '../assets/garden-environment' in project_text, 'Garden scenery is not bundled'
    assert manifest['upAxis'] == 'Y' and manifest['units'] == 'metres'
    assert manifest['plantingSurfaceY'] == 0 and manifest['plantingFootprint'] == {'width': 10, 'depth': 10}
    assert manifest['clouds'] == 'static' and manifest['collisionGeometry'] is False
    expected = {'floating-island.usdz', 'mountain-mist-backdrop.png'}
    assert {item['file'] for item in manifest['files']} == expected
    assert {p.name for p in folder.iterdir()} == expected | {'environment.json'}, 'Bundle only runtime scenery'
    for item in manifest['files']:
        assert Path(item['file']).name == item['file'], 'Unsafe environment path'
        data = (folder / item['file']).read_bytes()
        assert len(data) == item['bytes'], f"Environment size mismatch: {item['file']}"
        assert hashlib.sha256(data).hexdigest() == item['sha256'], f"Environment checksum mismatch: {item['file']}"
    png = (folder / 'mountain-mist-backdrop.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>IIBB', png[16:26]) == (1024, 1536, 8, 2), 'Background dimensions/colour contract'
    model = folder / 'floating-island.usdz'
    with zipfile.ZipFile(model) as archive:
        assert archive.testzip() is None
        assert any(p.endswith(('.usd', '.usdc', '.usda')) for p in archive.namelist())
        assert any(p.endswith('.png') for p in archive.namelist()), 'Grass texture must stay embedded'
        for info in archive.infolist():
            assert not info.filename.startswith('/') and '..' not in Path(info.filename).parts
            assert info.compress_type == zipfile.ZIP_STORED, 'USDZ entries must remain uncompressed'
            with model.open('rb') as stream:
                stream.seek(info.header_offset + 26)
                name_len, extra_len = struct.unpack('<HH', stream.read(4))
            assert (info.header_offset + 30 + name_len + extra_len) % 64 == 0, 'USDZ alignment'
    print('PASS: approved floating island/backdrop checksums, embedded texture, USDZ alignment and fixed Y=0 footprint.')


if __name__ == '__main__':
    repo = Path(__file__).resolve().parents[2]
    validate_garden_environment(repo, (repo / 'frontend/MovementForest.xcodeproj/project.pbxproj').read_text())
