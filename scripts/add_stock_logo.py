import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOGO_DIR = ROOT / "flutter_app" / "assets" / "company_logos"
MANIFEST = ROOT / "flutter_app" / "lib" / "stock_logo_assets.dart"


def write_manifest() -> None:
    symbols = sorted(path.stem.upper() for path in LOGO_DIR.glob("*.png"))
    entries = "\n".join(f"  '{symbol}'," for symbol in symbols)
    MANIFEST.write_text(
        "\n".join(
            [
                "const curatedStockLogoSymbols = <String>{",
                entries,
                "};",
                "",
            ]
        ),
        encoding="utf-8",
    )
def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python3 scripts/add_stock_logo.py SYMBOL /path/to/logo.png")

    symbol = sys.argv[1].strip().upper()
    source = Path(sys.argv[2]).expanduser().resolve()
    if not symbol:
        raise SystemExit("Symbol is required")
    if not source.exists() or not source.is_file():
        raise SystemExit(f"Logo file not found: {source}")
    if source.suffix.lower() != ".png":
        raise SystemExit("Use a PNG logo file")

    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    destination = LOGO_DIR / f"{symbol}.png"
    shutil.copyfile(source, destination)
    write_manifest()
    print(f"Added {symbol} logo: {destination}")


if __name__ == "__main__":
    main()
