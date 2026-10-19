#!/usr/bin/env python3
"""Headless Finder layout assembly/inspection. Does not sign, install or launch apps."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

PINNED = {'dmgbuild': '1.6.7', 'ds-store': '1.3.1', 'mac-alias': '2.2.2'}
WINDOW = ((180, 180), (640, 420))
POSITIONS = {'Tokens.app': (170, 220), 'Applications': (470, 220)}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dependencies():
    versions = {name: importlib.metadata.version(name) for name in PINNED}
    if versions != PINNED:
        raise RuntimeError('Installer layout dependencies differ from requirements-dmg.txt')
    return versions


def settings(app, background):
    return {
        'format': 'UDZO', 'filesystem': 'HFS+', 'files': [str(app)],
        'symlinks': {'Applications': '/Applications'},
        'background': str(background), 'window_rect': WINDOW,
        'default_view': 'icon-view', 'icon_locations': POSITIONS,
        'icon_size': 96, 'text_size': 14, 'label_pos': 'bottom',
        'arrange_by': None, 'grid_spacing': 80,
        'show_status_bar': False, 'show_tab_view': False,
        'show_toolbar': False, 'show_pathbar': False, 'show_sidebar': False,
        'show_icon_preview': False, 'show_item_info': False,
        # SetFile -aE adds FinderInfo to the signed app and breaks strict codesign
        # verification. Finder handles the application bundle's display name.
        'hide_extensions': [],
        'include_icon_view_settings': True, 'include_list_view_settings': False,
    }


def inspect_layout(mount, background):
    """Read persisted image metadata; actual Finder pixels remain separate proof."""
    from ds_store import DSStore
    mount, background = Path(mount), Path(background)
    visible = sorted(p.name for p in mount.iterdir() if not p.name.startswith('.'))
    if visible != ['Applications', 'Tokens.app']:
        raise RuntimeError('Unexpected visible installer contents')
    link = mount / 'Applications'
    if not link.is_symlink() or link.readlink() != Path('/Applications'):
        raise RuntimeError('Installer Applications link is invalid')
    if digest(mount / '.background.tiff') != digest(background):
        raise RuntimeError('Installer background differs from reviewed asset')
    with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
        window = store['.']['bwsp']
        icons = store['.']['icvp']
        view = store['.']['icvl']
        positions = {name: store[name]['Iloc'] for name in POSITIONS}
    if view != (b'type', b'icnv'):
        raise RuntimeError('Installer does not use icon view')
    if window.get('WindowBounds') != '{{180, 180}, {640, 420}}':
        raise RuntimeError('Installer window bounds changed')
    if any(window.get(key) is not False for key in ['ShowStatusBar', 'ShowTabView',
            'ShowToolbar', 'ShowPathbar', 'ShowSidebar']):
        raise RuntimeError('Installer window chrome changed')
    if (icons.get('iconSize') != 96 or icons.get('textSize') != 14
            or icons.get('arrangeBy') != 'none' or icons.get('labelOnBottom') is not True
            or icons.get('backgroundType') != 2 or not icons.get('backgroundImageAlias')):
        raise RuntimeError('Installer icon/background settings changed')
    if positions != POSITIONS:
        raise RuntimeError('Installer icon positions changed')
    return {'schema': 1, 'status': 'metadata-verified', 'visible_contents': visible,
            'window_size': [640, 420], 'icon_size': 96,
            'icon_positions': {k: list(v) for k, v in positions.items()},
            'background_sha256': digest(background),
            'ds_store_sha256': digest(mount / '.DS_Store'),
            'applications_alias': '/Applications', 'finder_pixels_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'inspect'])
    parser.add_argument('--background', type=Path, required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--mount', type=Path)
    args = parser.parse_args()
    versions = dependencies()
    background = args.background.resolve(strict=True)
    if background.suffix.lower() != '.tiff' or background.is_symlink():
        raise RuntimeError('Expected a reviewed regular TIFF installer background')
    if args.action == 'build':
        import dmgbuild
        app = args.app.resolve(strict=True)
        if app.name != 'Tokens.app' or not app.is_dir() or args.output.exists():
            raise RuntimeError('Expected Tokens.app and a fresh image output')
        events = []
        dmgbuild.build_dmg(str(args.output), 'Tokens', settings=settings(app, background),
                           lookForHiDPI=False, detach_retries=3, callback=events.append)
        print(json.dumps({'status': 'assembled', 'dependencies': versions, 'events': events}))
    else:
        print(json.dumps(inspect_layout(args.mount, background)))


if __name__ == '__main__':
    main()
