# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pillow",
# ]
# ///
#
# Create Project Zomboid Compatible Tileset from PNG
#
# Usage:
#   cd MySpatialRefuge
#   uv run utils/create_tileset.py <png_path> <tileset_name> [width] [height]
#
# Examples:
#   uv run utils/create_tileset.py path/to/sprite.png sacred_core 64 128
#   uv run utils/create_tileset.py sprites/my_tile.png my_tiles 64 64
#
"""
Create Project Zomboid Compatible Tileset from PNG

This script creates the necessary files for a custom PZ tileset:
1. Copies PNG to texturepacks/ folder
2. Creates .tiles definition in newtiledefinitions/tiles/
3. Adds entry to Tilesets.txt

Output sprite name: {tileset_name}_0 (use in SACRED_RELIC config)
"""

import os
import sys
import shutil
from pathlib import Path
from PIL import Image

# Default paths
MOD_ROOT = Path(__file__).parent.parent
MEDIA_PATH = MOD_ROOT / "Contents" / "mods" / "myspatialrefuge" / "42.13" / "media"


def create_tileset(png_path: str, tileset_name: str, tile_width: int = 64, tile_height: int = 128):
    """
    Create a PZ-compatible tileset from a PNG file.
    
    Args:
        png_path: Path to the source PNG file
        tileset_name: Name for the tileset (lowercase, no spaces)
        tile_width: Width of each tile in pixels (default 64)
        tile_height: Height of each tile in pixels (default 128)
    """
    
    png_path = Path(png_path)
    if not png_path.exists():
        print(f"Error: PNG file not found: {png_path}")
        return False
    
    # Validate tileset name
    tileset_name = tileset_name.lower().replace(" ", "_").replace("-", "_")
    
    # Open image to get dimensions
    try:
        img = Image.open(png_path)
        img_width, img_height = img.size
        print(f"Image size: {img_width}x{img_height}")
    except Exception as e:
        print(f"Error opening image: {e}")
        return False
    
    # Calculate number of tiles
    tiles_x = max(1, img_width // tile_width)
    tiles_y = max(1, img_height // tile_height)
    total_tiles = tiles_x * tiles_y
    
    print(f"Tile size: {tile_width}x{tile_height}")
    print(f"Tiles in image: {tiles_x}x{tiles_y} = {total_tiles} total")
    
    # Create output directories
    texturepacks_dir = MEDIA_PATH / "texturepacks"
    tiles_def_dir = MEDIA_PATH / "newtiledefinitions" / "tiles"
    
    texturepacks_dir.mkdir(parents=True, exist_ok=True)
    tiles_def_dir.mkdir(parents=True, exist_ok=True)
    
    # Copy PNG to texturepacks with proper name
    output_png = texturepacks_dir / f"{tileset_name}.png"
    shutil.copy2(png_path, output_png)
    print(f"Copied PNG to: {output_png}")
    
    # Create .tiles file (tile properties)
    tiles_content = generate_tiles_file(tileset_name, total_tiles, tile_width, tile_height)
    tiles_file = tiles_def_dir / f"{tileset_name}.tiles"
    tiles_file.write_text(tiles_content)
    print(f"Created tiles file: {tiles_file}")
    
    # Create Tilesets.txt entry
    tilesets_txt = tiles_def_dir / "Tilesets.txt"
    tilesets_entry = generate_tilesets_entry(tileset_name, tiles_x, tiles_y)
    
    # Append to existing or create new
    if tilesets_txt.exists():
        existing = tilesets_txt.read_text()
        if tileset_name not in existing:
            with open(tilesets_txt, 'a') as f:
                f.write("\n" + tilesets_entry)
            print(f"Appended to: {tilesets_txt}")
        else:
            print(f"Tileset already in Tilesets.txt")
    else:
        tilesets_txt.write_text(f"version = 0\nrevision = 1\n\n{tilesets_entry}")
        print(f"Created Tilesets.txt: {tilesets_txt}")
    
    print(f"\n[OK] Tileset '{tileset_name}' created successfully!")
    print(f"\nTo use this sprite in your mod:")
    print(f"  SACRED_RELIC = \"{tileset_name}_0\"")
    print(f"\nSprite names available: {tileset_name}_0", end="")
    if total_tiles > 1:
        print(f" to {tileset_name}_{total_tiles-1}")
    else:
        print()
    
    return True


def generate_tiles_file(tileset_name: str, tile_count: int, tile_width: int, tile_height: int) -> str:
    """Generate the .tiles file content."""
    
    lines = [
        f"# Tileset: {tileset_name}",
        f"# Generated automatically",
        f"# Tile size: {tile_width}x{tile_height}",
        f"# Total tiles: {tile_count}",
        "",
    ]
    
    for i in range(tile_count):
        # Basic tile definition
        lines.append(f"tile {tileset_name}_{i}")
        lines.append("{")
        lines.append(f"    sprite = {tileset_name}_{i}")
        lines.append("}")
        lines.append("")
    
    return "\n".join(lines)


def generate_tilesets_entry(tileset_name: str, tiles_x: int, tiles_y: int) -> str:
    """Generate Tilesets.txt entry."""
    
    return f"""tileset
{{
    file = {tileset_name}
    size = {tiles_x},{tiles_y}
}}
"""


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print("\nExample usage:")
        print("  uv run create_tileset.py path/to/sprite.png my_tileset_name")
        print("  uv run create_tileset.py path/to/sprite.png my_tileset_name 64 128")
        return
    
    png_path = sys.argv[1]
    tileset_name = sys.argv[2]
    tile_width = int(sys.argv[3]) if len(sys.argv) > 3 else 64
    tile_height = int(sys.argv[4]) if len(sys.argv) > 4 else 128
    
    create_tileset(png_path, tileset_name, tile_width, tile_height)


if __name__ == "__main__":
    main()
