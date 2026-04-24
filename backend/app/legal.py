from html import escape

from .settings import Settings


APP_NAME = "Stockfolio NG"


def _page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(title)}</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f5f7f8;
      --card: #ffffff;
      --text: #1f2933;
      --muted: #52606d;
      --accent: #0e7c66;
      --border: #d9e2ec;
    }}
    body {{
      margin: 0;
      font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.6;
    }}
    main {{
      max-width: 880px;
      margin: 0 auto;
      padding: 24px 16px 48px;
    }}
    article {{
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.06);
    }}
    h1, h2 {{
      line-height: 1.2;
      margin-top: 0;
    }}
    h1 {{
      margin-bottom: 12px;
    }}
    h2 {{
      margin-top: 28px;
      margin-bottom: 8px;
    }}
    p, li {{
      color: var(--muted);
    }}
    a {{
      color: var(--accent);
    }}
    code {{
      background: #edf2f7;
      padding: 2px 6px;
      border-radius: 4px;
    }}
    form {{
      display: grid;
      gap: 12px;
      margin-top: 18px;
    }}
    label {{
      display: grid;
      gap: 6px;
      color: var(--text);
      font-weight: 600;
    }}
    input, textarea, button {{
      font: inherit;
    }}
    input, textarea {{
      width: 100%;
      box-sizing: border-box;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px 12px;
      background: #fff;
    }}
    button {{
      width: fit-content;
      border: 0;
      border-radius: 8px;
      padding: 10px 14px;
      background: var(--accent);
      color: #fff;
      cursor: pointer;
    }}
    .note {{
      margin-top: 18px;
      padding: 12px 14px;
      border-radius: 8px;
      background: #eefbf7;
      color: var(--text);
      border: 1px solid #b8e5d8;
    }}
  </style>
</head>
<body>
  <main>
    <article>
      {body}
    </article>
  </main>
</body>
</html>"""


def render_privacy_policy_html(settings: Settings, *, privacy_url: str, deletion_url: str) -> str:
    contact_email = settings.contact_email
    contact_html = (
        f'<p>Privacy contact: <a href="mailto:{escape(contact_email)}">{escape(contact_email)}</a></p>'
        if contact_email
        else "<p>Privacy contact: Use the contact details listed on the app store listing or the support channel inside the app.</p>"
    )
    body = f"""
      <h1>{APP_NAME} Privacy Policy</h1>
      <p>This privacy policy explains how {APP_NAME} handles personal information and portfolio data when you use the app and related services.</p>
      <p><strong>Effective date:</strong> Current version available at <a href="{escape(privacy_url)}">{escape(privacy_url)}</a></p>
      {contact_html}

      <h2>Information we collect</h2>
      <ul>
        <li>Account information such as your email address, password hash, and optional profile fields like full name, phone number, address, city, and country.</li>
        <li>Portfolio information that you enter, such as stock symbols, share quantities, purchase prices, notes, and other investment tracking details.</li>
        <li>Operational records needed to keep the service running, such as authentication state, sync logs, and email delivery status.</li>
      </ul>

      <h2>How we use information</h2>
      <ul>
        <li>To create and secure your account.</li>
        <li>To show your portfolio, market data, charts, and related stock information.</li>
        <li>To send email verification messages and optional portfolio PDF reports.</li>
        <li>To operate, debug, secure, and improve the service.</li>
      </ul>

      <h2>How information is shared</h2>
      <p>We do not sell your personal data. Information may be processed by infrastructure and email providers used to operate the app, such as hosting, database, and email delivery services. Market data displayed in the app is sourced from public NGX-related endpoints, but your personal portfolio details are not sent to those market data sources for display.</p>

      <h2>Data retention and deletion</h2>
      <p>When you delete your account from within the app, we delete the account and associated portfolio records tied to that account, except where retention is required for security, fraud prevention, or legal compliance. Users may also submit an external deletion request using the public account deletion page: <a href="{escape(deletion_url)}">{escape(deletion_url)}</a>.</p>

      <h2>Security</h2>
      <p>We use authentication controls, hashed passwords, and service-level access controls designed to protect personal data. No system can guarantee absolute security, but we take reasonable steps to secure stored account and portfolio information.</p>

      <h2>Your choices</h2>
      <ul>
        <li>You can update your profile details inside the app.</li>
        <li>You can change your password inside the app.</li>
        <li>You can request email verification inside the app.</li>
        <li>You can delete your account inside the app or by using the public deletion request page.</li>
      </ul>
    """
    return _page(f"{APP_NAME} Privacy Policy", body)


def render_account_deletion_html(settings: Settings, *, post_url: str, privacy_url: str) -> str:
    contact_email = settings.contact_email
    contact_html = (
        f'<p>If you prefer, you can also contact <a href="mailto:{escape(contact_email)}">{escape(contact_email)}</a>.</p>'
        if contact_email
        else ""
    )
    body = f"""
      <h1>{APP_NAME} Account Deletion</h1>
      <p>This page lets users request deletion of a {APP_NAME} account outside the mobile app, as required for Google Play account deletion compliance.</p>
      <p>You can also delete your account directly inside the app from the <strong>Account</strong> section.</p>
      {contact_html}

      <h2>Request deletion</h2>
      <form id="deletion-form">
        <label>
          Email address used for the app account
          <input type="email" id="email" name="email" autocomplete="email" required>
        </label>
        <label>
          Reason (optional)
          <textarea id="reason" name="reason" rows="5" maxlength="2000"></textarea>
        </label>
        <button type="submit">Submit deletion request</button>
      </form>
      <div id="result" class="note" hidden></div>

      <h2>What happens next</h2>
      <p>Deletion requests are reviewed and processed against the account email provided. See the privacy policy for data handling and retention details: <a href="{escape(privacy_url)}">{escape(privacy_url)}</a>.</p>

      <script>
        const form = document.getElementById('deletion-form');
        const result = document.getElementById('result');
        form.addEventListener('submit', async (event) => {{
          event.preventDefault();
          result.hidden = true;
          const payload = {{
            email: document.getElementById('email').value.trim(),
            reason: document.getElementById('reason').value.trim() || null
          }};
          const response = await fetch('{escape(post_url)}', {{
            method: 'POST',
            headers: {{ 'Content-Type': 'application/json' }},
            body: JSON.stringify(payload)
          }});
          const data = await response.json().catch(() => ({{ message: 'Request submitted.' }}));
          result.textContent = data.message || 'Request submitted.';
          result.hidden = false;
          if (response.ok) {{
            form.reset();
          }}
        }});
      </script>
    """
    return _page(f"{APP_NAME} Account Deletion", body)
