import json
import unittest
from native_mail import NativeMailIntent, MailInvalid, MailUnavailable
from native_mail_envelope import NativeMailEnvelope


class NativeMailEnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.codec = NativeMailEnvelope(bytes(range(32)))
        self.id = '971b34b2-3b78-4c49-8d39-9471749af452'
        self.intent = NativeMailIntent('owner@example.invalid', 'reset-password', '704193', self.id)
        self.context = {'uid': 'synthetic-user', 'purpose': 'password-reset.v1',
                        'delivery_id': self.id, 'now': 1700000001}
        self.envelope = self.codec.seal(uid=self.context['uid'], purpose=self.context['purpose'],
            intent=self.intent, issued_at=1700000000, expires_at=1700000600)

    def test_roundtrip_stores_no_plain_recipient_or_code(self):
        saved = json.dumps(self.envelope)
        self.assertNotIn(self.intent.recipient, saved)
        self.assertNotIn(self.intent.code, saved)
        self.assertEqual(self.codec.open(self.envelope, **self.context), self.intent)
        self.assertNotIn(self.intent.code, repr(self.codec.open(self.envelope, **self.context)))

    def test_account_purpose_and_challenge_binding(self):
        for field, value in [('uid', 'another-user'), ('purpose', 'register-email.v1'),
                            ('delivery_id', 'b8f94a27-a73d-43f1-a70d-3f7f1661f64e')]:
            with self.subTest(field=field), self.assertRaises(MailUnavailable):
                self.codec.open(self.envelope, **{**self.context, field: value})

    def test_expiry_clock_and_lifetime(self):
        for now in [1699999999, 1700000600, True, 1700000001.0]:
            with self.subTest(now=now), self.assertRaises(MailUnavailable):
                self.codec.open(self.envelope, **{**self.context, 'now': now})
        self.assertEqual(self.codec.open(self.envelope, **{**self.context, 'now': 1700000599}), self.intent)
        with self.assertRaises(MailInvalid):
            self.codec.seal(uid='synthetic-user', purpose='password-reset.v1', intent=self.intent,
                            issued_at=1700000000, expires_at=1700000601)

    def test_tamper_metadata_cipher_and_key(self):
        for field, value in [('version', 'v2'), ('uid', 'another-user'),
                             ('issuedAt', 1700000001), ('expiresAt', 1700000601),
                             ('ciphertext', self.envelope['ciphertext'][:-4] + 'AAAA')]:
            broken = {**self.envelope, field: value}
            with self.subTest(field=field), self.assertRaises(MailUnavailable):
                self.codec.open(broken, **self.context)
        with self.assertRaises(MailUnavailable):
            NativeMailEnvelope(bytes(range(1,33))).open(self.envelope, **self.context)

    def test_exact_envelope_shape_and_canonical_encoding(self):
        for broken in [{**self.envelope, 'recipient': self.intent.recipient},
                       {k:v for k,v in self.envelope.items() if k != 'ciphertext'},
                       {**self.envelope, 'ciphertext': self.envelope['ciphertext']+'\n'},
                       {**self.envelope, 'expiresAt': True},
                       {**self.envelope, 'ciphertext': []}]:
            with self.subTest(broken=broken), self.assertRaises(MailUnavailable):
                self.codec.open(broken, **self.context)

    def test_transport_validation_and_purpose_consistency(self):
        for purpose in [[], None, 'other']:
            with self.subTest(purpose=purpose), self.assertRaises(MailInvalid):
                self.codec.seal(uid='synthetic-user', purpose=purpose, intent=self.intent,
                                issued_at=1700000000, expires_at=1700000600)
        for intent in [NativeMailIntent('owner@example.invalid\r\nBcc: x@x.invalid',
                                      'reset-password','704193',self.id),
                       NativeMailIntent('owner@example.invalid','verify-email','704193',self.id),
                       NativeMailIntent('owner@example.invalid','reset-password','70419',self.id)]:
            with self.subTest(intent=repr(intent)), self.assertRaises(MailInvalid):
                self.codec.seal(uid='synthetic-user', purpose='password-reset.v1', intent=intent,
                                issued_at=1700000000, expires_at=1700000600)

    def test_randomized_ciphertext_same_fixed_delivery(self):
        second = self.codec.seal(uid='synthetic-user', purpose='password-reset.v1', intent=self.intent,
                                 issued_at=1700000000, expires_at=1700000600)
        self.assertNotEqual(second['ciphertext'], self.envelope['ciphertext'])
        self.assertEqual(self.codec.open(second, **self.context), self.intent)
        verify = NativeMailIntent('owner@example.invalid','verify-email','704193',self.id)
        signup = self.codec.seal(uid='synthetic-user',purpose='register-email.v1',intent=verify,
                                issued_at=1700000000, expires_at=1700000600)
        self.assertEqual(self.codec.open(signup, **{**self.context,'purpose':'register-email.v1'}), verify)


if __name__ == '__main__':
    unittest.main()
