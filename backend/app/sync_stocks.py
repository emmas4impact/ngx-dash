from .database import SessionLocal
from .services import sync_stocks


def main() -> None:
    with SessionLocal() as db:
        source, stock_count, history_count = sync_stocks(db, include_history=True)
        print(f"Synced {stock_count} stocks and {history_count} history rows from {source}.")


if __name__ == "__main__":
    main()
