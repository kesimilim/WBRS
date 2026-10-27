import hashlib
import unittest
from urllib.parse import urlsplit,parse_qs
from runtime_donations import donation_checkout
from runtime_mutations import RuntimeInvalidRequest,RuntimeUnavailable

class DonationTests(unittest.TestCase):
    def test_exact_amount_signature_and_no_client_secret(self):
        env={'CLRS_ROBOKASSA_MERCHANT_LOGIN':'WBRS','CLRS_ROBOKASSA_PASSWORD1':'synthetic-test-only','CLRS_ROBOKASSA_TEST_MODE':'0'}
        result=donation_checkout(env,12345); url=urlsplit(result['url']);q=parse_qs(url.query)
        self.assertEqual((url.scheme,url.netloc,url.path),('https','auth.robokassa.ru','/Merchant/Index.aspx'))
        self.assertEqual(q['OutSum'],['123.45']);self.assertEqual(q['InvId'],['0'])
        self.assertEqual(q['SignatureValue'],[hashlib.md5(b'WBRS:123.45:0:synthetic-test-only').hexdigest()])
        self.assertNotIn('synthetic-test-only',str(result));self.assertNotIn('IsTest',q)
        self.assertFalse(result['test']);self.assertEqual(result['amountMinor'],12345)
        for amount in [True,99,10_000_001,1.1,'100']:
            with self.assertRaises(RuntimeInvalidRequest):donation_checkout(env,amount)
        with self.assertRaises(RuntimeUnavailable):donation_checkout({},100)
