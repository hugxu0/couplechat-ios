from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
CONCEPT_DIR = ROOT / "Docs" / "AppIconConcepts"
ICON_DIR = ROOT / "Sources" / "App" / "Assets.xcassets" / "AppIcon.appiconset"
SELECTED_ICON = CONCEPT_DIR / "selected-cat-bubble-source.png"


def gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (size, size), top)
    pixels = image.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(size):
            pixels[x, y] = color
    return image.convert("RGBA")


def rounded_bubble(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], fill, tail_side: str) -> None:
    x0, y0, x1, y1 = box
    radius = (y1 - y0) // 3
    draw.rounded_rectangle(box, radius=radius, fill=fill)
    if tail_side == "left":
        draw.polygon([(x0 + 80, y1 - 10), (x0 + 18, y1 + 58), (x0 + 138, y1 - 28)], fill=fill)
    else:
        draw.polygon([(x1 - 82, y1 - 10), (x1 - 18, y1 + 58), (x1 - 138, y1 - 28)], fill=fill)


def heart(draw: ImageDraw.ImageDraw, center: tuple[int, int], size: int, fill) -> None:
    cx, cy = center
    s = size
    draw.polygon(
        [
            (cx, cy + s),
            (cx - s, cy - s // 4),
            (cx - s, cy - s * 3 // 4),
            (cx - s * 2 // 3, cy - s),
            (cx, cy - s // 2),
            (cx + s * 2 // 3, cy - s),
            (cx + s, cy - s // 4),
        ],
        fill=fill,
    )


def concept_sakura(size: int = 1024) -> Image.Image:
    image = gradient(size, (255, 239, 244), (235, 137, 164))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse((240, 220, 790, 790), fill=(100, 37, 73, 55))
    shadow = shadow.filter(ImageFilter.GaussianBlur(44))
    image.alpha_composite(shadow)

    draw = ImageDraw.Draw(image)
    rounded_bubble(draw, (178, 290, 728, 660), (255, 255, 255, 245), "left")
    rounded_bubble(draw, (330, 390, 846, 760), (91, 39, 72, 255), "right")
    heart(draw, (514, 510), 86, (245, 132, 161, 255))
    draw.ellipse((260, 170, 278, 188), fill=(255, 255, 255, 150))
    draw.ellipse((760, 235, 780, 255), fill=(255, 255, 255, 130))
    return image.convert("RGB")


def concept_night(size: int = 1024) -> Image.Image:
    image = gradient(size, (14, 24, 67), (62, 32, 91))
    draw = ImageDraw.Draw(image)
    draw.ellipse((190, 164, 825, 800), outline=(255, 219, 235, 115), width=7)
    draw.ellipse((245, 214, 735, 704), fill=(251, 219, 232, 255))
    draw.ellipse((350, 170, 795, 610), fill=(37, 43, 93, 255))
    rounded_bubble(draw, (230, 430, 690, 700), (255, 178, 201, 255), "left")
    rounded_bubble(draw, (392, 520, 820, 770), (255, 247, 231, 255), "right")
    for x, y, r in [(150, 170, 8), (820, 178, 7), (130, 700, 5), (860, 740, 6), (795, 350, 5)]:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 210))
    heart(draw, (527, 612), 47, (178, 92, 145, 255))
    return image.convert("RGB")


def concept_cat(size: int = 1024) -> Image.Image:
    image = gradient(size, (255, 247, 232), (255, 196, 177))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse((210, 245, 815, 820), fill=(117, 54, 45, 45))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(42)))
    draw = ImageDraw.Draw(image)
    rounded_bubble(draw, (182, 270, 838, 768), (255, 255, 255, 235), "right")
    orange = (232, 113, 75, 255)
    draw.polygon([(300, 400), (350, 270), (470, 360), (670, 360), (790, 270), (752, 480)], fill=orange)
    draw.ellipse((292, 355, 780, 790), fill=orange)
    draw.ellipse((420, 520, 458, 572), fill=(84, 45, 47, 255))
    draw.ellipse((614, 520, 652, 572), fill=(84, 45, 47, 255))
    draw.polygon([(536, 608), (505, 640), (567, 640)], fill=(255, 215, 205, 255))
    draw.arc((481, 622, 536, 685), 10, 165, fill=(84, 45, 47, 255), width=8)
    draw.arc((536, 622, 591, 685), 15, 175, fill=(84, 45, 47, 255), width=8)
    return image.convert("RGB")


def selected_cat_bubble() -> Image.Image:
    """Normalize the supplied icon's black rounded-corner backdrop for iOS masking."""
    image = Image.open(SELECTED_ICON).convert("RGB")
    width, height = image.size
    pixels = image.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        background = (
            round(255 - 2 * t),
            round(207 - 37 * t),
            round(219 - 20 * t),
        )
        for x in range(width):
            red, green, blue = pixels[x, y]
            # The submitted image has only near-black pixels in its outer corners.
            # Fill them with the surrounding sakura gradient so iOS can apply its own mask.
            if red < 220 and green < 220 and blue < 220:
                pixels[x, y] = background
    return image


def save_icon(image: Image.Image, path: Path, size: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if size is not None:
        image = image.resize((size, size), Image.Resampling.LANCZOS)
    image.save(path, format="PNG", optimize=True)


def main() -> None:
    sakura = concept_sakura()
    night = concept_night()
    cat = concept_cat()
    selected = selected_cat_bubble()
    save_icon(sakura, CONCEPT_DIR / "sakura-bubbles.png")
    save_icon(night, CONCEPT_DIR / "midnight-orbit.png")
    save_icon(cat, CONCEPT_DIR / "cat-whisper.png")

    sizes = {
        "icon-20@2x.png": 40,
        "icon-20@3x.png": 60,
        "icon-29@2x.png": 58,
        "icon-29@3x.png": 87,
        "icon-40@2x.png": 80,
        "icon-40@3x.png": 120,
        "icon-60@2x.png": 120,
        "icon-60@3x.png": 180,
        "icon-76@1x.png": 76,
        "icon-76@2x.png": 152,
        "icon-83.5@2x.png": 167,
        "icon-1024.png": 1024,
    }
    for filename, size in sizes.items():
        save_icon(selected, ICON_DIR / filename, size)


if __name__ == "__main__":
    main()
