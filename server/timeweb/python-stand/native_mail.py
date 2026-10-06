"""Default-off transactional mail transport for the existing CLRS Yandex box.

No HTTP route, recipient discovery, mailbox read or arbitrary message template.
The caller must persist a single-use, account-bound challenge and delivery
intent first. An unknown DATA result must not be retried automatically.
"""
from __future__ import annotations

from dataclasses import dataclass
from email.message import EmailMessage
from email.policy import SMTP
import math
import re
import smtplib
import ssl
import threading
import time


class MailInvalid(ValueError):
    pass


class MailUnavailable(Exception):
    pass


class MailOutcomeUnknown(MailUnavailable):
    """The server may already have accepted DATA; no automatic resend."""


@dataclass(frozen=True, repr=False)
class NativeMailIntent:
    recipient: str
    purpose: str
    code: str
    delivery_id: str

    def message(self):
        if (not isinstance(self.recipient, str) or len(self.recipient) > 320
                or re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@"
                                r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252}[A-Za-z0-9])?", self.recipient) is None
                or ".." in self.recipient or len(self.recipient.rsplit("@", 1)[1]) > 253
                or not isinstance(self.purpose, str)
                or self.purpose not in {"verify-email", "reset-password"}
                or not isinstance(self.code, str) or re.fullmatch(r"[0-9]{6}", self.code) is None
                or not isinstance(self.delivery_id, str)
                or re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", self.delivery_id) is None):
            raise MailInvalid()
        message = EmailMessage()
        message["From"] = "CLRS <supp.lrs@yandex.ru>"
        message["To"] = self.recipient
        message["Message-ID"] = f"<clrs.{self.delivery_id}@yandex.ru>"
        message["Subject"] = ("Подтверждение почты CLRS" if self.purpose == "verify-email"
                              else "Восстановление пароля CLRS")
        action = "подтверждения почты" if self.purpose == "verify-email" else "восстановления пароля"
        message.set_content(f"Код {action} в CLRS: {self.code}\n\n"
                            "Код действует 10 минут. Никому не сообщайте его.\n"
                            "Если вы не запрашивали этот код, проигнорируйте письмо.\n")
        raw = message.as_bytes(policy=SMTP)
        if len(raw) > 8192:
            raise MailInvalid()
        return raw


class _Delivery:
    def __init__(self):
        self.done = threading.Event()
        self.cancel = threading.Event()
        self.lock = threading.Lock()
        self.smtp = None
        self.data_started = False
        self.accepted = False
        self.error = None

    def abort(self):
        self.cancel.set()
        with self.lock:
            sock = getattr(self.smtp, "sock", None)
        if sock is not None:
            try:
                sock.shutdown(2)
            except Exception:
                pass
            try:
                sock.close()
            except Exception:
                pass


class NativeMailTransport:
    def __init__(self, password, *, smtp_factory=smtplib.SMTP_SSL,
                 clock=time.monotonic, deadline_seconds=8):
        if (not isinstance(password, str) or not 1 <= len(password) <= 4096
                or any(c in password for c in "\0\r\n")
                or not 0 < deadline_seconds <= 8):
            raise MailUnavailable()
        self._password = password
        self._factory = smtp_factory
        self._clock = clock
        self._seconds = deadline_seconds
        self._lock = threading.Lock()
        self._active = None
        self._closed = False

    @classmethod
    def from_env(cls, env):
        if env.get("CLRS_MAIL_ENABLED") != "1":
            return None
        if (env.get("CLRS_MAIL_HOST", "smtp.yandex.ru") != "smtp.yandex.ru"
                or env.get("CLRS_MAIL_PORT", "465") != "465"
                or env.get("CLRS_MAIL_USER", "supp.lrs@yandex.ru") != "supp.lrs@yandex.ru"):
            raise MailUnavailable()
        return cls(env.get("CLRS_MAIL_PASSWORD"))

    def close(self):
        with self._lock:
            self._closed = True
            active = self._active
            self._password = ""
        if active is not None:
            active.abort()

    def deliver(self, intent, *, deadline=None):
        if type(intent) is not NativeMailIntent:
            raise MailInvalid()
        raw = intent.message()
        now = self._clock()
        if deadline is not None and (type(deadline) not in (int, float)
                or not math.isfinite(deadline) or deadline <= now):
            raise MailInvalid()
        # Absolute verified outbox budget is never reset by waiting/dispatch.
        # The existing shared transport slot and its global cap stay intact.
        deadline = min(now + self._seconds, deadline) if deadline is not None else now + self._seconds
        with self._lock:
            if self._closed or self._active is not None:
                raise MailUnavailable()
            work = _Delivery()
            self._active = work
            password = self._password

        def check():
            if work.cancel.is_set() or self._clock() >= deadline:
                raise MailUnavailable()

        def worker():
            smtp = None
            try:
                check()
                context = ssl.create_default_context()
                check()
                smtp = self._factory("smtp.yandex.ru", 465,
                    context=context, timeout=min(2, deadline - self._clock()))
                with work.lock:
                    work.smtp = smtp
                check()
                smtp.login("supp.lrs@yandex.ru", password)
                check()
                code, _ = smtp.mail("supp.lrs@yandex.ru")
                if code != 250:
                    raise MailUnavailable()
                check()
                code, _ = smtp.rcpt(intent.recipient)
                if code not in (250, 251):
                    raise MailUnavailable()
                check()
                # Once DATA starts, an I/O failure is conservatively unknown.
                # A fixed Message-ID helps identify the delivery but is not a
                # promise that an SMTP provider deduplicates repeated sends.
                with work.lock:
                    work.data_started = True
                code, _ = smtp.data(raw)
                if code != 250:
                    raise MailOutcomeUnknown()
                check()
                work.accepted = True
            except Exception:
                work.error = MailOutcomeUnknown() if work.data_started else MailUnavailable()
            finally:
                if smtp is not None:
                    try:
                        smtp.close()
                    except Exception:
                        pass
                with self._lock:
                    if self._active is work:
                        self._active = None
                work.done.set()

        try:
            threading.Thread(target=worker, daemon=True, name="clrs-native-mail").start()
        except Exception:
            with self._lock:
                if self._active is work:
                    self._active = None
            raise MailUnavailable() from None
        if not work.done.wait(max(0, deadline - self._clock())):
            work.abort()
            with work.lock:
                unknown = work.data_started
            raise MailOutcomeUnknown() if unknown else MailUnavailable()
        with self._lock:
            closed = self._closed
        if closed or work.cancel.is_set() or self._clock() >= deadline:
            raise MailOutcomeUnknown() if work.data_started else MailUnavailable()
        if work.error is not None:
            raise work.error from None
        if not work.accepted:
            raise MailUnavailable()
        return {"deliveryId": intent.delivery_id, "smtpAccepted": True}
