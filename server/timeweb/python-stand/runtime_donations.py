"""Checkout signing only. Opening or returning from checkout is not payment.

Robokassa protocol: https://docs.robokassa.ru/ru/pay-interface
The provider assigns InvId when zero; no balance or purchase is credited here.
"""
import hashlib
from urllib.parse import urlencode
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable


def donation_checkout(env, amount_minor):
    if type(amount_minor) is not int or not 100 <= amount_minor <= 10_000_000:
        raise RuntimeInvalidRequest()
    merchant = env.get('CLRS_ROBOKASSA_MERCHANT_LOGIN')
    secret = env.get('CLRS_ROBOKASSA_PASSWORD1')
    test = env.get('CLRS_ROBOKASSA_TEST_MODE')
    if merchant != 'WBRS' or type(secret) is not str or not 8 <= len(secret) <= 256 or test not in ('0','1'):
        raise RuntimeUnavailable()
    amount = f'{amount_minor//100}.{amount_minor%100:02}'
    signature = hashlib.md5(f'{merchant}:{amount}:0:{secret}'.encode('utf8')).hexdigest()
    query = {'MerchantLogin': merchant, 'OutSum': amount, 'InvId': '0',
             'Description': 'Добровольное пожертвование', 'SignatureValue': signature}
    if test == '1': query['IsTest'] = '1'
    return {'url': 'https://auth.robokassa.ru/Merchant/Index.aspx?' + urlencode(query),
            'amountMinor': amount_minor, 'test': test == '1'}
