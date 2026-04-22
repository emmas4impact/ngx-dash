import base64
import html
import io
import smtplib
from datetime import datetime, timezone
from email.message import EmailMessage

import requests
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from .models import User
from .settings import Settings


class EmailDeliveryError(RuntimeError):
    pass


def send_email(
    settings: Settings,
    *,
    to_email: str,
    subject: str,
    body: str,
    attachment: tuple[str, bytes, str] | None = None,
) -> None:
    if not settings.email_enabled:
        raise RuntimeError("Email is not configured")

    if settings.resend_api_key:
        try:
            send_resend_email(
                settings,
                to_email=to_email,
                subject=subject,
                body=body,
                attachment=attachment,
            )
        except requests.Timeout as exc:
            raise EmailDeliveryError("Resend API timed out while sending email") from exc
        except requests.RequestException as exc:
            raise EmailDeliveryError(f"Resend API request failed: {exc}") from exc
        return

    message = EmailMessage()
    message["From"] = settings.from_email
    message["To"] = to_email
    message["Subject"] = subject
    message.set_content(body)

    if attachment:
        filename, payload, mime_type = attachment
        maintype, subtype = mime_type.split("/", 1)
        message.add_attachment(payload, maintype=maintype, subtype=subtype, filename=filename)

    try:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=20) as smtp:
            if settings.smtp_use_tls:
                smtp.starttls()
            if settings.smtp_username and settings.smtp_password:
                smtp.login(settings.smtp_username, settings.smtp_password)
            smtp.send_message(message)
    except TimeoutError as exc:
        raise EmailDeliveryError(
            "SMTP timed out while sending email. If you are using Resend, set RESEND_API_KEY and RESEND_FROM_EMAIL "
            "on the Railway backend service so the app uses Resend HTTPS API instead of SMTP."
        ) from exc
    except OSError as exc:
        raise EmailDeliveryError(f"SMTP delivery failed: {exc}") from exc


def send_resend_email(
    settings: Settings,
    *,
    to_email: str,
    subject: str,
    body: str,
    attachment: tuple[str, bytes, str] | None = None,
) -> None:
    payload: dict = {
        "from": settings.from_email,
        "to": [to_email],
        "subject": subject,
        "text": body,
        "html": f"<p>{html.escape(body).replace(chr(10), '<br>')}</p>",
    }
    if attachment:
        filename, content, _mime_type = attachment
        payload["attachments"] = [
            {
                "filename": filename,
                "content": base64.b64encode(content).decode("ascii"),
            }
        ]

    response = requests.post(
        "https://api.resend.com/emails",
        headers={
            "Authorization": f"Bearer {settings.resend_api_key}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=20,
    )
    if response.status_code >= 400:
        raise RuntimeError(f"Resend API error {response.status_code}: {response.text}")


def portfolio_report_pdf(user: User, holdings: list[dict]) -> bytes:
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=A4, title="NGX Portfolio Report")
    styles = getSampleStyleSheet()
    story = [
        Paragraph("NGX Portfolio Report", styles["Title"]),
        Paragraph(f"Investor: {user.full_name or user.email}", styles["Normal"]),
        Paragraph(f"Email: {user.email}", styles["Normal"]),
        Paragraph(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}", styles["Normal"]),
        Spacer(1, 16),
    ]

    total_value = sum(float(item["total_value"]) for item in holdings)
    total_cost = sum(float(item["total_cost"]) for item in holdings)
    profit_loss = total_value - total_cost
    story.extend(
        [
            Paragraph(f"Portfolio value: NGN {total_value:,.2f}", styles["Heading3"]),
            Paragraph(f"Amount invested: NGN {total_cost:,.2f}", styles["Normal"]),
            Paragraph(f"Profit / loss: NGN {profit_loss:,.2f}", styles["Normal"]),
            Spacer(1, 12),
        ]
    )

    rows = [["Symbol", "Shares", "Avg Price", "Current", "Value", "P/L"]]
    for item in holdings:
        rows.append(
            [
                item["stock_symbol"],
                f"{float(item['quantity']):,.2f}",
                f"{float(item['avg_purchase_price']):,.2f}",
                "-" if item["current_price"] is None else f"{float(item['current_price']):,.2f}",
                f"{float(item['total_value']):,.2f}",
                f"{float(item['profit_loss']):,.2f}",
            ]
        )

    if len(rows) == 1:
        story.append(Paragraph("No holdings have been added yet.", styles["Normal"]))
    else:
        table = Table(rows, repeatRows=1)
        table.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0E7C66")),
                    ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                    ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#C8D0D8")),
                    ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                    ("ALIGN", (1, 1), (-1, -1), "RIGHT"),
                    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F5F7F9")]),
                ]
            )
        )
        story.append(table)

    doc.build(story)
    return buffer.getvalue()
