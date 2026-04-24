# NGX Portfolio Dashboard

This repo now contains two paths:

- `main_dashboard.py`: the existing Streamlit dashboard that reads portfolio rows from Google Sheets.
- `backend/` + `flutter_app/`: the new Postgres-backed API and Flutter app for web, Android, and iOS.

The new stack is the migration path away from Google Sheets. Postgres becomes the source of truth for users, holdings, stock master data, and historical prices.

## What The New Stack Covers

- User registration and login with bearer-token authentication.
- Dockerized Postgres with schema initialization.
- Stock master table for all NGX securities, prices, margins, volume, sector, and market cap where available.
- Per-user portfolio holdings with manual stock/value entry.
- Portfolio calculations: current value, cost basis, profit/loss, and profit/loss percent.
- One-year stock history endpoint and Flutter chart screen.
- Flutter client scaffolded for web, Android, and iOS from one codebase.

## Project Structure

- `backend/app/main.py`: FastAPI routes.
- `backend/app/models.py`: SQLAlchemy database models.
- `backend/app/services.py`: portfolio and stock sync services.
- `backend/app/ngx_client.py`: NGX market-data integration.
- `db/init/001_schema.sql`: Postgres schema used by Docker on first boot.
- `docker-compose.yml`: Postgres plus API service.
- `Dockerfile.api`: API container image.
- `flutter_app/`: Flutter web/Android/iOS app.
- `main_dashboard.py`, `data_loader.py`: legacy Streamlit dashboard.

## Data Source

The current Google Sheet is no longer required for the new API.

For all listed equities, the backend calls the same NGX endpoint you used in Google Apps Script:

```text
GET https://doclib.ngxgroup.com/REST/api/statistics/ticker?$filter=TickerType eq 'EQUITIES'&page_size=1000
```

It maps `SYMBOL`, `Value`, `PercChange`, and `Id` into Postgres as stock symbol, current price, percent change, and numeric ticker id. The historical chart endpoint does not accept that numeric `Id`, so chart ids still come from `config.py` under `STOCK_ID_MAPPING` when known. If the NGX ticker endpoint is temporarily unavailable, the sync falls back to those mapped symbols for local testing.

Historical chart data uses the existing NGX chart endpoint already present in the project:

```text
https://doclib.ngxgroup.com/REST/api/stockchartdata/{ngx_id}
```

## Local Setup

1. Copy environment config:

```bash
cp .env.example .env
```

2. Update `.env`:

```bash
POSTGRES_DB=ngx_dash
POSTGRES_USER=your-local-db-user
POSTGRES_PASSWORD=your-local-db-password
DATABASE_URL=postgresql+psycopg://your-local-db-user:your-local-db-password@postgres:5432/ngx_dash
JWT_SECRET_KEY=replace-with-a-long-random-secret
CORS_ORIGINS=http://localhost:8080,http://localhost:3000
ADMIN_EMAILS=you@example.com
```

Keep `.env` out of git. Railway should use Railway Variables for these same values, not committed files.

3. Start Postgres and the API:

```bash
docker compose up --build
```

The API runs at:

```text
http://localhost:8000
```

Postgres is available to host tools on `localhost:5433`. Inside Docker, the API still connects to `postgres:5432`.

4. Open the API docs:

```text
http://localhost:8000/docs
```

5. Create a user with `POST /auth/register`, then sign in with `POST /auth/login`.

6. Sync stock data with an authenticated request:

```bash
curl -X POST "http://localhost:8000/admin/sync/stocks?include_history=false" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

Use `include_history=true` when you want to backfill chart data. That is slower because it calls the chart endpoint per stock.

## Flutter App

Run the app in a separate terminal:

```bash
cd flutter_app
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

For Android emulator:

```bash
flutter run -d android --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

For iOS simulator on the same machine:

```bash
flutter run -d ios --dart-define=API_BASE_URL=http://localhost:8000
```

The Flutter app includes:

- Sign in / register.
- Portfolio summary.
- Add, edit, and delete holdings.
- Manual current price entry for custom/private holdings.
- All-stocks list with price, percent change, margin, and volume.
- Market status banner above the stocks list, refreshed from the cached API.
- One-year chart screen per chart-enabled stock with opening and closing price lines.
- Admin-only dashboard for sync status, manual sync, and debug logs.

## Useful API Endpoints

- `POST /auth/register`
- `POST /auth/login`
- `GET /me`
- `GET /stocks`
- `GET /stocks/{symbol}`
- `GET /stocks/{symbol}/history?months=12`
- `GET /market/status`
- `POST /portfolio/holdings`
- `GET /portfolio/holdings`
- `DELETE /portfolio/holdings/{symbol}`
- `POST /admin/sync/stocks?include_history=false`
- `GET /admin/sync/status`
- `GET /admin/sync/logs`

The first registered user is promoted to superuser automatically for local setup. You can also set comma-separated admin emails with `ADMIN_EMAILS`.

## Railway Deployment

You do not need Docker Hub for Railway. The recommended setup is to connect Railway to this GitHub repo and let Railway build the backend directly from `Dockerfile.api`.

Use Railway services like this:

- `postgres`: Railway PostgreSQL service.
- `api`: FastAPI service built from `Dockerfile.api`.
- `web`: Flutter web static service, built with the production API URL.

Set backend variables in Railway, not in code:

```text
DATABASE_URL=<Railway Postgres connection URL>
JWT_SECRET_KEY=<long random secret>
CORS_ORIGINS=https://your-frontend-domain
ADMIN_EMAILS=you@example.com
```

For local Docker Compose, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` are also required in `.env`.

Docker Hub is optional. It is useful only if you want CI to publish a reusable API image such as `yourname/ngx-dash-api:latest`. For Railway, deploying from the repo/Dockerfile is simpler and avoids one more moving part.

## Verification

Commands run during this migration:

```bash
PYTHONPYCACHEPREFIX=.pycache python3 -m compileall backend
docker compose config
cd flutter_app && flutter analyze
cd flutter_app && flutter test
```

## Hosting Suggestions

As of 2026-04-22, these are practical cheap/free options:

- Best simple test deployment: [Render](https://render.com/docs/free). Render has free web services and free static sites, and a free Postgres option, but Render documents that free Postgres expires after 30 days and has a 1 GB limit. Good for demos, not durable production data.
- Best cheap all-in-one deployment: [Railway](https://docs.railway.com/pricing). Railway currently lists a free plan for experimentation and a Hobby plan around $5/month with included usage. Good for the FastAPI container plus Postgres when you want fewer moving parts.
- Best managed Postgres free start: [Supabase](https://supabase.com/docs/guides/platform/database-size). Supabase documents a Free Plan database size limit of 500 MB before read-only mode. Good if you want managed Postgres and may later use Supabase Auth instead of custom auth.
- Best Flutter web static hosting: [Firebase Hosting](https://firebase.google.com/products/hosting/). Firebase Hosting includes SSL/CDN and a free starting allowance for static sites. Use this for `flutter build web` output while the API/Postgres live elsewhere.
- Lowest-cost container option when comfortable with ops: [Fly.io](https://fly.io/docs/about/pricing/). Fly.io lists small shared CPU machines and volume pricing, but you need to pay attention to storage, snapshots, and database maintenance.

Recommended path:

1. Local development: Docker Compose.
2. First public test: Render or Railway.
3. Longer-running cheap production: Railway API + Supabase Postgres, or one Railway project for both API and Postgres.
4. Flutter web: Firebase Hosting or Render static site.
5. Mobile: publish the same Flutter app to Play Store and App Store once the API URL points to production.

## Legacy Streamlit App

The original Streamlit app still works with Google Sheets:

```bash
pip install -r requirements.txt
streamlit run main_dashboard.py
```

Keep it around until the Postgres/Flutter flow has enough data and you are comfortable switching users over.
