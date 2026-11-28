"""Build the Windows icon from the shared high-resolution artwork."""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / "Resources" / "GaoJiXuIcon.png"
ICON = ROOT / "src" / "gaojixu" / "assets" / "GaoJiXu.ico"
SIZES = (16, 20, 24, 28, 30, 32, 36, 40, 42, 48, 56, 60, 64, 72, 80, 84, 96, 112, 128, 256)


def generate(destination: Path) -> None:
    with Image.open(SOURCE) as artwork:
        icon = artwork.convert("RGBA")
    size = icon.width
    if size != icon.height or size < max(SIZES):
        raise ValueError("The shared icon must be a high-resolution square.")
    corners = Image.new("L", icon.size)
    ImageDraw.Draw(corners).rounded_rectangle((0, 0, size - 1, size - 1), radius=round(size * 0.18), fill=255)
    frames = []
    for side in SIZES:
        dimensions = (side, side)
        frame = icon.resize(dimensions, Image.Resampling.LANCZOS)
        frame.putalpha(corners.resize(dimensions, Image.Resampling.BOX))
        frames.append(frame)
    frames[-1].save(destination, format="ICO", sizes=[frame.size for frame in frames], append_images=frames[:-1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path, default=ICON)
    generate(parser.parse_args().destination)
