import os
import sys
import traceback

import uvicorn


def main() -> None:
    port = int(os.getenv("PORT", "8000"))
    try:
        import backend.app.main  # noqa: F401
    except Exception:
        print("Failed to import backend.app.main before starting Uvicorn.", file=sys.stderr)
        traceback.print_exc()
        raise

    uvicorn.run("backend.app.main:app", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
